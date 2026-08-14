import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart';

import '../../shared/relay/relay.dart';
import '../../shared/utils/string_utils.dart';
import 'channel.dart';
import 'unread_badge/should_notify_for_event.dart';

const lastMessageQueryBatchSize = 100;
const lastMessageQueryTotalTimeout = Duration(seconds: 8);
const liveSubscriptionReadyTimeout = Duration(seconds: 8);

Future<List<NostrEvent>> fetchChannelHistoryBatch(
  RelaySessionNotifier session,
  List<NostrFilter> filters, {
  required String operation,
  required bool Function() isCancelled,
}) async {
  if (filters.isEmpty || isCancelled()) return const [];

  try {
    return await session.queryRelay(filters);
  } catch (error) {
    debugPrint(
      '[ChannelsNotifier] batched $operation failed; '
      'using bounded websocket fallback: $error',
    );
  }

  const fallbackConcurrency = 4;
  final events = <NostrEvent>[];
  for (var start = 0; start < filters.length; start += fallbackConcurrency) {
    if (isCancelled()) break;
    final end = min(start + fallbackConcurrency, filters.length);
    final results = await Future.wait(
      filters.sublist(start, end).map((filter) async {
        try {
          return await session.fetchHistory(filter);
        } catch (_) {
          return const <NostrEvent>[];
        }
      }),
    );
    if (isCancelled()) break;
    for (final result in results) {
      events.addAll(result);
    }
  }
  return events;
}

Future<Set<String>> fetchHiddenDmIds(
  RelaySessionNotifier session,
  String myPk,
) async {
  try {
    final events = await session.fetchHistory(NostrFilters.hiddenDms(myPk));
    if (events.isEmpty) return const {};
    NostrEvent latest = events.first;
    for (final event in events.skip(1)) {
      if (event.createdAt > latest.createdAt) {
        latest = event;
      }
    }
    return {
      for (final tag in latest.tags)
        if (tag.length >= 2 && tag[0] == 'h') tag[1],
    };
  } catch (_) {
    return const {};
  }
}

/// Build a [Channel] from a kind:39000 metadata event.
///
/// [displayNames] maps lowercase participant pubkey → resolved label and is
/// used to populate [Channel.participants] for DMs so [Channel.displayLabel]
/// can render real names instead of the relay-canonical "DM" name.
Channel channelFromMeta(
  NostrEvent event, {
  required bool isMember,
  Map<String, String> displayNames = const {},
}) {
  final data = ChannelData.fromEvent(event);
  final participants = data.channelType == 'dm'
      ? [
          for (final pk in data.participantPubkeys)
            displayNames[pk.toLowerCase()] ?? shortPubkey(pk),
        ]
      : const <String>[];
  return Channel(
    id: data.id,
    name: data.name,
    channelType: data.channelType,
    visibility: data.visibility,
    description: data.description,
    topic: data.topic,
    createdBy: event.pubkey,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      event.createdAt * 1000,
      isUtc: true,
    ),
    memberCount: 0,
    lastMessageAt: null,
    // `archivedAt` doubles as both the archived-state flag and the timestamp.
    // The kind:39000 metadata only carries `["archived", "true"]`, not the
    // moment of archival, so we stamp the event's `createdAt` — that's when
    // the relay republished the metadata, which is the closest signal we have.
    archivedAt: data.isArchived
        ? DateTime.fromMillisecondsSinceEpoch(
            event.createdAt * 1000,
            isUtc: true,
          )
        : null,
    participants: participants,
    participantPubkeys: data.participantPubkeys,
    isMember: isMember,
    ttlSeconds: data.ttlSeconds,
    ttlDeadline: data.ttlDeadline,
  );
}

List<List<Channel>> chunkChannelsForLastMessageQuery(List<Channel> channels) =>
    [
      for (
        var start = 0;
        start < channels.length;
        start += lastMessageQueryBatchSize
      )
        channels.sublist(
          start,
          min(start + lastMessageQueryBatchSize, channels.length),
        ),
    ];

List<NostrFilter> buildChannelLastMessageFilters(List<Channel> channels) => [
  for (final channel in channels)
    NostrFilter(
      kinds: EventKind.channelMessageEventKinds,
      tags: {
        '#h': [channel.id],
      },
      limit: channel.isDm ? 1 : 20,
    ),
];

Map<String, int> resolveChannelLastMessages(
  List<Channel> channels,
  Iterable<NostrEvent> events, {
  required String myPk,
  Set<String> mutedChannelIds = const {},
}) {
  final channelsById = {for (final channel in channels) channel.id: channel};
  final result = <String, int>{};
  for (final event in events) {
    final channelId = event.channelId;
    final channel = channelId == null ? null : channelsById[channelId];
    if (channel == null) continue;
    if (!channel.isDm &&
        !shouldNotifyForEvent(
          event,
          myPk,
          mutedChannelIds: mutedChannelIds,
          channelId: channelId,
        )) {
      continue;
    }
    final current = result[channel.id];
    if (current == null || event.createdAt > current) {
      result[channel.id] = event.createdAt;
    }
  }
  return result;
}

typedef TaskDelay = Future<void> Function(Duration duration);
typedef TaskErrorHandler = void Function(Object error);
typedef CancellationTimer =
    Timer Function(Duration duration, void Function() callback);
typedef PendingSubscription =
    Future<void Function()> Function(Future<void> cancelled);

Future<void Function()> subscribeWhenReadyWithTimeout(
  PendingSubscription subscribe,
  Completer<void> cancellation, {
  Duration timeout = liveSubscriptionReadyTimeout,
  CancellationTimer timerFactory = Timer.new,
}) async {
  var timedOut = false;
  final timer = timerFactory(timeout, () {
    timedOut = true;
    if (!cancellation.isCompleted) cancellation.complete();
  });
  try {
    return await subscribe(cancellation.future);
  } on RelaySubscriptionCancelledException {
    if (timedOut) throw TimeoutException('Relay EOSE timed out after $timeout');
    rethrow;
  } finally {
    timer.cancel();
  }
}

Future<void> runPacedTasks(
  List<Future<void> Function()> tasks, {
  required int maxConcurrent,
  required Duration startInterval,
  required bool Function() isCancelled,
  TaskDelay delay = defaultTaskDelay,
  TaskErrorHandler onError = _defaultTaskErrorHandler,
}) async {
  if (maxConcurrent < 1) throw ArgumentError.value(maxConcurrent);
  var nextTask = 0;
  var firstStart = true;
  Future<void> startPermit = Future.value();

  Future<bool> acquireStartPermit() async {
    if (firstStart) {
      firstStart = false;
    } else {
      startPermit = startPermit.then((_) => delay(startInterval));
      await startPermit;
    }
    return !isCancelled();
  }

  Future<void> worker() async {
    while (true) {
      final index = nextTask++;
      if (index >= tasks.length) return;
      if (!await acquireStartPermit()) return;
      try {
        await tasks[index]();
      } catch (error) {
        onError(error);
      }
    }
  }

  await Future.wait([
    for (var i = 0; i < min(maxConcurrent, tasks.length); i++) worker(),
  ]);
}

Future<void> defaultTaskDelay(Duration duration) =>
    Future<void>.delayed(duration);

void _defaultTaskErrorHandler(Object error) {
  debugPrint('[ChannelsNotifier] paced task failed: $error');
}

bool sameStringSet(Set<String> left, Set<String> right) =>
    left.length == right.length && left.containsAll(right);

String? observedUnreadRootId(NostrEvent event) =>
    isBroadcastReply(event) ? null : event.threadReference.rootId;

bool isBroadcastReply(NostrEvent event) => event.tags.any(
  (tag) => tag.length >= 2 && tag[0] == 'broadcast' && tag[1] == '1',
);

Set<String> readRootIdSet(String? raw) {
  if (raw == null || raw.isEmpty) return {};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return {};
    return {
      for (final value in decoded)
        if (value is String) value,
    };
  } catch (_) {
    return {};
  }
}

String encodeRootIdSet(Set<String> values) => jsonEncode(values.toList());
