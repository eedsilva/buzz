import 'dart:async';
import 'dart:math';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../shared/relay/relay.dart';
import '../../shared/theme/theme_provider.dart';
import '../../shared/utils/string_utils.dart';
import 'channel.dart';
import 'channel_sync.dart';
import 'channel_management_provider.dart'
    show ChannelMember, channelDetailsProvider;
import 'channel_mutes/channel_mutes_provider.dart';
import '../../shared/read_state/read_state_provider.dart';
import 'thread_follows/thread_follows_provider.dart';
import 'unread_badge/is_high_priority_event.dart';
import 'unread_badge/observed_unread_event.dart';
import 'unread_badge/should_notify_for_event.dart';

const _channelTypeOrder = {'stream': 0, 'forum': 1, 'dm': 2};
const _unreadCatchUpLimit = 1000;
const _unreadCatchUpConcurrency = 4;
const _unreadCatchUpStartInterval = Duration(milliseconds: 125);
const _participatedRootIdsPrefix = 'buzz-thread-participation.v1';
const _authoredRootIdsPrefix = 'buzz-thread-authored.v1';

/// Loads the user's channel list from the relay over WebSocket.
///   1. Fetch kind:39002 membership events tagged `#p:<my-pubkey>` to find
///      the channel ids I'm a member of.
///   2. Fetch the corresponding kind:39000 channel metadata events.
/// Live updates are layered on top via per-channel subscriptions on the
/// `#h` tag for any of the visible channel event kinds — incoming events
/// bump `lastMessageAt` for that channel.
class ChannelsNotifier extends AsyncNotifier<List<Channel>> {
  static const _backstopInterval = Duration(seconds: 60);

  final Map<String, ({Object attempt, void Function() unsubscribe})>
  _liveSubscriptionsByChannel = {};
  final Map<String, Completer<void>> _pendingSubscriptionCancellations = {};
  final Set<String> _terminallyClosedChannelIds = {};
  Future<void> _liveSubscriptionQueue = Future.value();
  List<Channel> _desiredLiveChannels = const [];
  Set<String> _desiredLiveChannelIds = const {};
  int _subscriptionVersion = 0;
  String? _subscriptionRelayBaseUrl;
  Timer? _backstopTimer;
  int _unreadCatchUpGeneration = 0;
  Set<String> _unreadCatchUpChannelIds = const {};
  bool _bufferingBootstrapLiveEvents = false;
  final List<NostrEvent> _bootstrapLiveEvents = [];
  final Map<String, int> _latestObservedByChannel = {};
  final Map<String, Map<String, ObservedUnreadEvent>>
  _observedUnreadEventsByChannel = {};
  Set<String> _participatedRootIds = {};
  Set<String> _authoredRootIds = {};
  String? _threadInterestPubkey;
  bool _hasLoaded = false;
  String? _memberSnapshotRelayBaseUrl;
  String? _memberSnapshotPubkey;
  Map<String, List<ChannelMember>> _memberSnapshotsByChannelId = const {};

  /// The member snapshot already returned while loading the channel list.
  ///
  /// Mention autocomplete can use this synchronously while its independent
  /// channel-member refresh is still in flight.
  List<ChannelMember> cachedMembersForChannel(String channelId) =>
      _memberSnapshotsByChannelId[channelId] ?? const [];

  Map<String, int> get latestObservedByChannel =>
      Map.unmodifiable(_latestObservedByChannel);
  Map<String, Map<String, ObservedUnreadEvent>>
  get observedUnreadEventsByChannel =>
      Map<String, Map<String, ObservedUnreadEvent>>.unmodifiable({
        for (final entry in _observedUnreadEventsByChannel.entries)
          entry.key: Map<String, ObservedUnreadEvent>.unmodifiable(entry.value),
      });

  @override
  Future<List<Channel>> build() async {
    final relayBaseUrl = ref.watch(relayConfigProvider).baseUrl;
    final pubkey = ref.watch(myPubkeyProvider)?.toLowerCase();
    if (_memberSnapshotRelayBaseUrl != relayBaseUrl ||
        _memberSnapshotPubkey != pubkey) {
      _memberSnapshotRelayBaseUrl = relayBaseUrl;
      _memberSnapshotPubkey = pubkey;
      _memberSnapshotsByChannelId = const {};
    }
    final connected = Completer<void>();
    final sessionState = ref.read(relaySessionProvider);
    final waitingForInitialConnection =
        sessionState.status != SessionStatus.connected;
    ref.listen(relaySessionProvider, (previous, next) {
      if (next.status != SessionStatus.connected) {
        _cancelPendingLiveSubscriptions();
        if (previous?.status == SessionStatus.connected) {
          // In-flight history requests cannot always be aborted at the transport
          // boundary. Invalidate their generation so late responses are ignored,
          // and clear the completed-set marker so reconnect catch-up restarts.
          _unreadCatchUpGeneration++;
          _unreadCatchUpChannelIds = const {};
        }
        return;
      }
      if (waitingForInitialConnection &&
          !_hasLoaded &&
          !connected.isCompleted) {
        connected.complete();
      } else if (previous?.status != SessionStatus.connected) {
        _terminallyClosedChannelIds.clear();
        unawaited(_backstopRefresh());
      }
    });

    // Re-fetch when the app returns to foreground so channels created on
    // another device while mobile was backgrounded appear immediately.
    ref.listen(appLifecycleProvider, (prev, next) {
      if (next == AppLifecycleState.resumed) {
        refresh();
      }
    });

    ref.onDispose(() {
      _clearLiveSubscriptions();
      _latestObservedByChannel.clear();
      _observedUnreadEventsByChannel.clear();
      _backstopTimer?.cancel();
      _backstopTimer = null;
      _unreadCatchUpGeneration++;
      _unreadCatchUpChannelIds = const {};
      _bufferingBootstrapLiveEvents = false;
      _bootstrapLiveEvents.clear();
    });

    if (sessionState.status != SessionStatus.connected) {
      // Keep the prior community's cache visible until the new relay connects.
      if (_hasLoaded) return state.value ?? const [];
      await connected.future;
    }

    return _fetch(subscribeLive: true);
  }

  Future<List<Channel>> _fetch({
    bool subscribeLive = false,
    bool fetchLastMessage = true,
  }) async {
    final channels = await _fetchChannels(
      subscribeLive: subscribeLive,
      fetchLastMessage: fetchLastMessage,
    );
    _hasLoaded = true;
    return channels;
  }

  Future<List<Channel>> _fetchChannels({
    bool subscribeLive = false,
    bool fetchLastMessage = true,
  }) async {
    final myPk = ref.read(myPubkeyProvider);
    if (myPk == null) throw StateError('No signing identity available');
    _loadThreadInterestStores(myPk);

    final session = ref.read(relaySessionProvider.notifier);

    // Step 1: find the channels I'm a member of via kind:39002.
    final memberships = <NostrEvent>[];
    {
      int? until;
      const pageSize = 500;
      while (true) {
        final page = await session.fetchHistory(
          NostrFilter(
            kinds: const [39002],
            tags: {
              '#p': [myPk],
            },
            limit: pageSize,
            until: until,
          ),
        );
        memberships.addAll(page);
        if (page.length < pageSize) break;
        until = page.map((e) => e.createdAt).reduce(min) - 1;
      }
    }
    final channelIds = memberships
        .map((e) => e.getTagValue('d'))
        .whereType<String>()
        .toSet()
        .toList();
    _cacheMemberSnapshots(memberships, replaceAll: true);
    if (channelIds.isEmpty) {
      if (subscribeLive) await _subscribeLive(const []);
      return const [];
    }

    // Step 2: pull channel metadata in one batched filter.
    final metas = await session.fetchHistory(
      NostrFilters.channelMetadata(channelIds),
    );

    // Dedupe by `d` tag (channel id) — kind:39000 is parameterized-replaceable,
    // so logically there's exactly one current event per id, but stale revisions
    // from before the relay's d_tag backfill can linger. Keep the highest
    // `created_at` per id so the latest channel_type / name wins.
    final latestMetaPerId = <String, NostrEvent>{};
    for (final event in metas) {
      if (event.kind != 39000) continue;
      final id = event.getTagValue('d');
      if (id == null) continue;
      final existing = latestMetaPerId[id];
      if (existing == null || event.createdAt > existing.createdAt) {
        latestMetaPerId[id] = event;
      }
    }
    final dedupedMetas = latestMetaPerId.values;

    // Resolve DM participant display names. Relay stores DM channels with
    // literal name="DM"; pure-Nostr architecture pushes name resolution to
    // the client, so collect non-self participant pubkeys across all DM
    // metas and batch-fetch their kind:0 profiles in one round-trip.
    final dmParticipants = <String>{};
    final myPkLower = myPk.toLowerCase();
    for (final event in dedupedMetas) {
      final data = ChannelData.fromEvent(event);
      if (data.channelType != 'dm') continue;
      for (final pk in data.participantPubkeys) {
        final lower = pk.toLowerCase();
        if (lower != myPkLower) dmParticipants.add(lower);
      }
    }

    final displayNames = <String, String>{};
    if (dmParticipants.isNotEmpty) {
      final profileEvents = await session.fetchHistory(
        NostrFilters.profilesBatch(dmParticipants.toList()),
      );
      for (final event in profileEvents) {
        if (event.kind != 0) continue;
        final profile = ProfileData.fromEvent(event);
        final label = profile.displayName?.trim().isNotEmpty == true
            ? profile.displayName!.trim()
            : profile.nip05?.trim().isNotEmpty == true
            ? profile.nip05!.trim()
            : shortPubkey(profile.pubkey);
        displayNames[profile.pubkey.toLowerCase()] = label;
      }
    }

    final hiddenDmIds = await fetchHiddenDmIds(session, myPk);

    final channels = <Channel>[];
    for (final event in dedupedMetas) {
      final channel = channelFromMeta(
        event,
        isMember: true,
        displayNames: displayNames,
      );
      if (channel.isDm && hiddenDmIds.contains(channel.id)) continue;
      // Ephemeral (TTL) channels are surfaced in the list with an
      // `_EphemeralBadge` rendered in `channels_page.dart` — they shouldn't be
      // hidden. Desktop shows them too. Previously dropped here unconditionally,
      // which made TTL channels invisible on iOS even when the user was a member.
      channels.add(channel);
    }

    // Batch-fetch member counts via kind:39002 membership events.
    final memberEvents = await session.fetchHistory(
      NostrFilter(
        kinds: const [39002],
        tags: {'#d': channelIds},
        limit: channelIds.length,
      ),
    );
    if (memberEvents.isNotEmpty) _cacheMemberSnapshots(memberEvents);
    final memberCounts = <String, int>{};
    for (final event in memberEvents) {
      final chId = event.getTagValue('d');
      if (chId == null) continue;
      final pTags = <String>{};
      for (final tag in event.tags) {
        if (tag.isNotEmpty && tag[0] == 'p' && tag.length > 1) {
          pTags.add(tag[1].toLowerCase());
        }
      }
      memberCounts[chId] = pTags.length;
    }
    for (var i = 0; i < channels.length; i++) {
      final count = memberCounts[channels[i].id];
      if (count != null) {
        channels[i] = channels[i].copyWith(memberCount: count);
      }
    }

    // Establish live callbacks before the bounded HTTP snapshot. During initial
    // build there is no published channel list to mutate, so buffer callbacks
    // and replay them onto the completed snapshot before returning it.
    final bufferBootstrapLiveEvents = subscribeLive && !_hasLoaded;
    if (bufferBootstrapLiveEvents) {
      _bootstrapLiveEvents.clear();
      _bufferingBootstrapLiveEvents = true;
    }
    Future<void>? bootstrapLiveSync;
    if (subscribeLive) {
      if (bufferBootstrapLiveEvents) {
        // Subscription admission is deliberately paced and may take longer than
        // the bounded snapshot. Run both concurrently; any not-yet-ready channel
        // is covered by unread catch-up after the live pass completes.
        bootstrapLiveSync = _subscribeLive(channels);
      } else {
        await _subscribeLive(channels);
      }
    }

    // Step 3: fetch the most recent message per channel to populate lastMessageAt.
    // kind:39000 metadata doesn't carry message timestamps, so channels load with
    // lastMessageAt: null. Without this, unread detection and badge computation
    // see every channel as having no messages. Skipped on backstop refreshes since
    // live subscriptions keep lastMessageAt current after the initial load.
    if (fetchLastMessage) {
      final activeChannels = [
        for (final channel in channels)
          if (channel.isMember && !channel.isArchived) channel,
      ];
      final lastMessageMap = <String, int>{};
      final mutedChannelIds = _mutedChannelIds();

      // Keep the HTTP request bounded for very large accounts. Each batch still
      // replaces hundreds of simultaneous WebSocket history subscriptions with
      // one authenticated /query request, while a failed batch does not erase
      // successful results from the others. The whole sequence shares the same
      // eight-second startup budget as the former individual history requests,
      // so a slow relay cannot delay live subscription setup once per batch.
      final queryStopwatch = Stopwatch()..start();
      for (final batch in chunkChannelsForLastMessageQuery(activeChannels)) {
        final remaining = lastMessageQueryTotalTimeout - queryStopwatch.elapsed;
        if (remaining <= Duration.zero) {
          debugPrint('[ChannelsNotifier] last-message query budget exhausted');
          break;
        }
        try {
          final events = await session.queryRelay(
            buildChannelLastMessageFilters(batch),
            timeout: remaining,
          );
          lastMessageMap.addAll(
            resolveChannelLastMessages(
              batch,
              events,
              myPk: myPk,
              mutedChannelIds: mutedChannelIds,
            ),
          );
        } catch (error) {
          debugPrint('[ChannelsNotifier] last-message batch failed: $error');
        }
      }

      for (var i = 0; i < channels.length; i++) {
        final ts = lastMessageMap[channels[i].id];
        if (ts != null) {
          channels[i] = channels[i].copyWith(
            lastMessageAt: DateTime.fromMillisecondsSinceEpoch(
              ts * 1000,
              isUtc: true,
            ),
          );
        }
      }
    }

    // Never let a refresh snapshot roll back a newer callback already applied
    // to the published list while the bounded HTTP batches were in flight.
    final publishedLastMessage = {
      for (final channel in state.value ?? const <Channel>[])
        if (channel.lastMessageAt != null) channel.id: channel.lastMessageAt!,
    };
    for (var i = 0; i < channels.length; i++) {
      final published = publishedLastMessage[channels[i].id];
      if (published != null &&
          (channels[i].lastMessageAt == null ||
              published.isAfter(channels[i].lastMessageAt!))) {
        channels[i] = channels[i].copyWith(lastMessageAt: published);
      }
    }

    channels.sort((left, right) {
      final typeOrder =
          (_channelTypeOrder[left.channelType] ?? 99) -
          (_channelTypeOrder[right.channelType] ?? 99);
      if (typeOrder != 0) return typeOrder;
      // Case-insensitive to match desktop's `localeCompare` ordering.
      return left.name.toLowerCase().compareTo(right.name.toLowerCase());
    });

    // Invalidate `channelDetailsProvider` entries whose archived state flipped
    // since the last fetch. Required because `channelDetailsProvider` is a
    // separate Riverpod cache and `Channel.mergeDetails(details)` overwrites
    // archivedAt from the cached details — so an active-then-archived channel
    // (e.g. TTL auto-archive by the relay reaper) could keep showing compose
    // and manage actions in the detail view until the cache expired naturally.
    //
    // Scoped narrowly to the archived flip — broader metadata staleness
    // (renames, topic changes, etc.) is a separate, pre-existing concern that
    // already affects this provider for other reasons.
    final prevById = <String, Channel>{
      for (final c in state.value ?? const <Channel>[]) c.id: c,
    };
    for (final channel in channels) {
      final prev = prevById[channel.id];
      if (prev != null && prev.isArchived != channel.isArchived) {
        ref.invalidate(channelDetailsProvider(channel.id));
      }
    }

    if (bufferBootstrapLiveEvents) {
      // Publish immediately after the bounded snapshot. Events from live REQs
      // already accepted are replayed now; later callbacks update published
      // state normally. The paced live pass continues in the background and
      // starts unread catch-up when complete, recovering the gap for channels
      // whose REQ was not accepted before their snapshot batch completed.
      _bufferingBootstrapLiveEvents = false;
      for (final event in _bootstrapLiveEvents) {
        _applyLiveEventToChannels(channels, event, myPk);
      }
      _bootstrapLiveEvents.clear();
      unawaited(bootstrapLiveSync!);
    }
    return channels;
  }

  void _cacheMemberSnapshots(
    Iterable<NostrEvent> events, {
    bool replaceAll = false,
  }) {
    final latestByChannelId = <String, NostrEvent>{};
    for (final event in events) {
      final channelId = event.getTagValue('d');
      if (channelId == null) continue;
      final current = latestByChannelId[channelId];
      if (current == null || event.createdAt > current.createdAt) {
        latestByChannelId[channelId] = event;
      }
    }

    final snapshots = replaceAll
        ? <String, List<ChannelMember>>{}
        : Map<String, List<ChannelMember>>.of(_memberSnapshotsByChannelId);
    snapshots.addAll({
      for (final entry in latestByChannelId.entries)
        entry.key: List.unmodifiable([
          for (final member in membersFromEvent(entry.value))
            ChannelMember(
              pubkey: member.pubkey,
              role: member.role,
              joinedAt: DateTime.fromMillisecondsSinceEpoch(
                entry.value.createdAt * 1000,
                isUtc: true,
              ),
            ),
        ]),
    });
    _memberSnapshotsByChannelId = Map.unmodifiable(snapshots);
  }

  /// Subscribe per-channel to live events (requires `#h` tag for relay
  /// channel-scoped fan-out). Also starts a 60s WS backstop poll to detect
  /// newly created channels we don't yet have subscriptions for.
  Future<void> _subscribeLive(List<Channel> channels) {
    final channelIds = {
      for (final channel in channels)
        if (channel.isMember && !channel.isArchived) channel.id,
    };
    final relayBaseUrl = ref.read(relayConfigProvider).baseUrl;
    if (!sameStringSet(_unreadCatchUpChannelIds, channelIds)) {
      // Stop admitting work from the old channel set while its replacement
      // live subscriptions are being established.
      _unreadCatchUpGeneration++;
    }
    for (final entry in _pendingSubscriptionCancellations.entries.toList()) {
      if (channelIds.contains(entry.key)) continue;
      _pendingSubscriptionCancellations.remove(entry.key);
      if (!entry.value.isCompleted) entry.value.complete();
    }
    if (!sameStringSet(_desiredLiveChannelIds, channelIds)) {
      _terminallyClosedChannelIds.clear();
    }
    _desiredLiveChannels = channels;
    _desiredLiveChannelIds = channelIds;
    final subscriptionVersion = ++_subscriptionVersion;

    final sync = _liveSubscriptionQueue.then(
      (_) =>
          _syncLiveSubscriptions(relayBaseUrl, subscriptionVersion, channels),
    );
    _liveSubscriptionQueue = sync.catchError((Object error, StackTrace stack) {
      debugPrint(
        '[ChannelsNotifier] live subscription sync failed: $error\n$stack',
      );
    });
    return sync;
  }

  Future<void> _syncLiveSubscriptions(
    String relayBaseUrl,
    int subscriptionVersion,
    List<Channel> channels,
  ) async {
    if (!ref.mounted ||
        ref.read(relaySessionProvider).status != SessionStatus.connected) {
      return;
    }

    if (subscriptionVersion != _subscriptionVersion) {
      await _syncLiveSubscriptions(
        ref.read(relayConfigProvider).baseUrl,
        _subscriptionVersion,
        _desiredLiveChannels,
      );
      return;
    }

    if (_subscriptionRelayBaseUrl != relayBaseUrl) {
      for (final cancellation in _pendingSubscriptionCancellations.values) {
        if (!cancellation.isCompleted) cancellation.complete();
      }
      _pendingSubscriptionCancellations.clear();
      for (final subscription in _liveSubscriptionsByChannel.values) {
        subscription.unsubscribe();
      }
      _liveSubscriptionsByChannel.clear();
      _subscriptionRelayBaseUrl = relayBaseUrl;
    }
    if (ref.read(relayConfigProvider).baseUrl != relayBaseUrl) {
      return;
    }
    final session = ref.read(relaySessionProvider.notifier);
    final channelIds = _desiredLiveChannelIds;

    for (final entry in _liveSubscriptionsByChannel.entries.toList()) {
      if (channelIds.contains(entry.key)) continue;
      _liveSubscriptionsByChannel.remove(entry.key);
      entry.value.unsubscribe();
    }

    final newChannelIds = [
      for (final channelId in channelIds)
        if (!_liveSubscriptionsByChannel.containsKey(channelId) &&
            !_terminallyClosedChannelIds.contains(channelId))
          channelId,
    ];
    final subscribeTasks = <Future<void> Function()>[
      for (final channelId in newChannelIds)
        () async {
          if (!ref.mounted ||
              ref.read(relaySessionProvider).status !=
                  SessionStatus.connected) {
            return;
          }
          try {
            final cancellation = Completer<void>();
            final attempt = Object();
            var terminallyClosed = false;
            _pendingSubscriptionCancellations[channelId] = cancellation;
            final unsubscribe = await subscribeWhenReadyWithTimeout(
              (cancelled) => session.subscribeWhenReady(
                NostrFilter(
                  kinds: EventKind.channelEventKinds,
                  tags: {
                    '#h': [channelId],
                  },
                  limit: 0,
                ),
                _handleLiveEvent,
                onClosed: (_) {
                  terminallyClosed = true;
                  final current = _liveSubscriptionsByChannel[channelId];
                  if (current?.attempt != attempt) return;
                  _liveSubscriptionsByChannel.remove(channelId);
                  _terminallyClosedChannelIds.add(channelId);
                  _unreadCatchUpChannelIds = Set.unmodifiable(
                    _unreadCatchUpChannelIds.difference({channelId}),
                  );
                },
                cancelled: cancelled,
              ),
              cancellation,
              timeout: ref.read(channelsLiveSubscriptionReadyTimeoutProvider),
            );
            _pendingSubscriptionCancellations.remove(channelId);
            if (terminallyClosed) {
              unsubscribe();
              return;
            }
            if (!ref.mounted) {
              unsubscribe();
              return;
            }
            if (ref.read(relaySessionProvider).status !=
                    SessionStatus.connected ||
                !_desiredLiveChannelIds.contains(channelId) ||
                ref.read(relayConfigProvider).baseUrl != relayBaseUrl ||
                _subscriptionRelayBaseUrl != relayBaseUrl) {
              unsubscribe();
              return;
            }
            final replaced = _liveSubscriptionsByChannel[channelId];
            if (replaced != null) {
              unsubscribe();
              return;
            }
            _liveSubscriptionsByChannel[channelId] = (
              attempt: attempt,
              unsubscribe: unsubscribe,
            );
          } on TimeoutException catch (_) {
          } on RelaySubscriptionCancelledException catch (_) {
          } catch (error) {
            debugPrint(
              '[ChannelsNotifier] live subscription failed for $channelId: $error',
            );
          } finally {
            _pendingSubscriptionCancellations.remove(channelId);
          }
        },
    ];
    await runPacedTasks(
      subscribeTasks,
      maxConcurrent: _unreadCatchUpConcurrency,
      startInterval: _unreadCatchUpStartInterval,
      isCancelled: () =>
          !ref.mounted ||
          subscriptionVersion != _subscriptionVersion ||
          ref.read(relaySessionProvider).status != SessionStatus.connected ||
          ref.read(relayConfigProvider).baseUrl != relayBaseUrl,
      delay: ref.read(channelsLiveSubscriptionDelayProvider),
    );

    if (!ref.mounted ||
        ref.read(relaySessionProvider).status != SessionStatus.connected) {
      return;
    }

    if (subscriptionVersion != _subscriptionVersion) {
      final desiredChannelIds = _desiredLiveChannelIds;
      for (final entry in _liveSubscriptionsByChannel.entries.toList()) {
        if (desiredChannelIds.contains(entry.key)) continue;
        _liveSubscriptionsByChannel.remove(entry.key);
        entry.value.unsubscribe();
      }
      return;
    }

    _startUnreadCatchUpIfNeeded([
      for (final channel in channels)
        if (_liveSubscriptionsByChannel.containsKey(channel.id)) channel,
    ]);

    _backstopTimer?.cancel();
    _backstopTimer = Timer.periodic(
      _backstopInterval,
      (_) => _backstopRefresh(),
    );
  }

  void _startUnreadCatchUpIfNeeded(List<Channel> channels) {
    final catchUpChannelIds = {
      for (final channel in channels)
        if (channel.isMember && !channel.isArchived) channel.id,
    };
    if (sameStringSet(_unreadCatchUpChannelIds, catchUpChannelIds)) return;
    _unreadCatchUpChannelIds = Set.unmodifiable(catchUpChannelIds);
    final catchUpGeneration = ++_unreadCatchUpGeneration;
    unawaited(_catchUpUnreadEvents(channels, catchUpGeneration));
  }

  Future<void> _catchUpUnreadEvents(
    List<Channel> channels,
    int catchUpGeneration,
  ) async {
    final myPk = ref.read(myPubkeyProvider);
    if (myPk == null) return;

    final session = ref.read(relaySessionProvider.notifier);
    final relayBaseUrl = ref.read(relayConfigProvider).baseUrl;
    bool isCancelled() =>
        !ref.mounted ||
        catchUpGeneration != _unreadCatchUpGeneration ||
        ref.read(relaySessionProvider).status != SessionStatus.connected ||
        ref.read(relayConfigProvider).baseUrl != relayBaseUrl;
    final mutedChannelIds = _mutedChannelIds();
    final ReadStateState readState;
    try {
      readState = ref.read(readStateProvider);
    } catch (error) {
      debugPrint('[ChannelsNotifier] unread catch-up skipped: $error');
      return;
    }
    final activeChannels = [
      for (final channel in channels)
        if (channel.isMember && !channel.isArchived) channel,
    ];
    final channelById = {
      for (final channel in activeChannels) channel.id: channel,
    };
    final readAtByChannel = {
      for (final channel in activeChannels)
        channel.id: readState.effectiveTimestamp(channel.id),
    };
    final filters = [
      for (final channel in activeChannels)
        NostrFilter(
          kinds: EventKind.channelMessageEventKinds,
          tags: {
            '#h': [channel.id],
          },
          since: (readAtByChannel[channel.id] ?? -1) + 1,
          limit: _unreadCatchUpLimit,
        ),
    ];

    try {
      final events = await fetchChannelHistoryBatch(
        session,
        filters,
        operation: 'unread catch-up',
        isCancelled: isCancelled,
      );
      if (isCancelled()) {
        return;
      }

      for (final event in events) {
        if (event.pubkey.toLowerCase() == myPk.toLowerCase()) {
          _recordSelfThreadInterest(event, myPk);
        }
      }

      for (final event in events) {
        final channelId = event.channelId;
        if (channelId == null) continue;
        final channel = channelById[channelId];
        if (channel == null) continue;
        final readAt = readAtByChannel[channelId];
        if (event.pubkey.toLowerCase() == myPk.toLowerCase()) continue;
        if (readAt != null && event.createdAt <= readAt) continue;
        if (!shouldNotifyForEvent(
          event,
          myPk,
          participatedRootIds: _participatedRootIds,
          followedRootIds: _followedRootIds(),
          authoredRootIds: _authoredRootIds,
          mutedChannelIds: mutedChannelIds,
          channelId: channel.id,
        )) {
          continue;
        }
        _recordUnreadEvent(channel, event, myPk);
        _mergeLastMessageAt(channel.id, event.createdAt);
      }
    } catch (error) {
      debugPrint('[ChannelsNotifier] unread catch-up failed: $error');
    }

    state = state.whenData((channels) => List<Channel>.of(channels));
  }

  void _mergeLastMessageAt(String channelId, int createdAt) {
    final eventTime = DateTime.fromMillisecondsSinceEpoch(
      createdAt * 1000,
      isUtc: true,
    );
    state = state.whenData((channels) {
      final index = channels.indexWhere((channel) => channel.id == channelId);
      if (index == -1) return channels;
      final channel = channels[index];
      if (channel.lastMessageAt != null &&
          !eventTime.isAfter(channel.lastMessageAt!)) {
        return channels;
      }
      final updated = List<Channel>.of(channels);
      updated[index] = channel.copyWith(lastMessageAt: eventTime);
      return updated;
    });
  }

  void _handleLiveEvent(NostrEvent event) {
    if (_bufferingBootstrapLiveEvents) {
      _bootstrapLiveEvents.add(event);
      return;
    }
    final myPk = ref.read(myPubkeyProvider);

    state = state.whenData((channels) {
      final updated = List<Channel>.of(channels);
      if (!_applyLiveEventToChannels(updated, event, myPk)) {
        refresh();
        return channels;
      }
      return updated;
    });
  }

  bool _applyLiveEventToChannels(
    List<Channel> channels,
    NostrEvent event,
    String? myPk,
  ) {
    final channelId = event.channelId;
    if (channelId == null) return true;
    final idx = channels.indexWhere((channel) => channel.id == channelId);
    if (idx == -1) return false;
    final channel = channels[idx];

    if (myPk != null && event.pubkey.toLowerCase() == myPk.toLowerCase()) {
      _recordSelfThreadInterest(event, myPk);
    }

    if (myPk != null &&
        shouldNotifyForEvent(
          event,
          myPk,
          participatedRootIds: _participatedRootIds,
          followedRootIds: _followedRootIds(),
          authoredRootIds: _authoredRootIds,
          mutedChannelIds: _mutedChannelIds(),
          channelId: channel.id,
        )) {
      _recordUnreadEvent(channel, event, myPk);
      final eventTime = DateTime.fromMillisecondsSinceEpoch(
        event.createdAt * 1000,
        isUtc: true,
      );
      if (channel.lastMessageAt == null ||
          eventTime.isAfter(channel.lastMessageAt!)) {
        channels[idx] = channel.copyWith(lastMessageAt: eventTime);
      }
    }
    return true;
  }

  Set<String> _mutedChannelIds() => {
    for (final entry in ref.read(channelMutesProvider).store.channels.entries)
      if (entry.value.muted) entry.key,
  };

  Set<String> _followedRootIds() =>
      ref.read(threadFollowsProvider).followedRootIds;

  void _loadThreadInterestStores(String pubkey) {
    final normalizedPubkey = pubkey.toLowerCase();
    if (_threadInterestPubkey == normalizedPubkey) return;
    _threadInterestPubkey = normalizedPubkey;
    try {
      final prefs = ref.read(savedPrefsProvider);
      _participatedRootIds = readRootIdSet(
        prefs.getString('$_participatedRootIdsPrefix:$normalizedPubkey'),
      );
      _authoredRootIds = readRootIdSet(
        prefs.getString('$_authoredRootIdsPrefix:$normalizedPubkey'),
      );
    } catch (_) {
      _participatedRootIds = {};
      _authoredRootIds = {};
    }
  }

  void _recordSelfThreadInterest(NostrEvent event, String pubkey) {
    final ref = event.threadReference;
    final target = ref.rootId != null ? _participatedRootIds : _authoredRootIds;
    final id = ref.rootId ?? event.id;
    if (!target.add(id)) return;
    _writeThreadInterestStores(pubkey);
  }

  void _writeThreadInterestStores(String pubkey) {
    final normalizedPubkey = pubkey.toLowerCase();
    try {
      final prefs = ref.read(savedPrefsProvider);
      prefs.setString(
        '$_participatedRootIdsPrefix:$normalizedPubkey',
        encodeRootIdSet(_participatedRootIds),
      );
      prefs.setString(
        '$_authoredRootIdsPrefix:$normalizedPubkey',
        encodeRootIdSet(_authoredRootIds),
      );
    } catch (_) {
      // Ignore storage failures; in-memory interest still works this session.
    }
  }

  void _recordUnreadEvent(Channel channel, NostrEvent event, String myPk) {
    final isThreadedReply =
        event.threadReference.parentId != null && !isBroadcastReply(event);
    final isHighPriority =
        channel.isDm || isHighPriorityEvent(event.tags, myPk);
    recordObservedUnreadEvent(
      _observedUnreadEventsByChannel,
      channel.id,
      makeObservedUnreadEvent(
        id: event.id,
        createdAt: event.createdAt,
        rootId: observedUnreadRootId(event),
        highPriority: isHighPriority,
        channelType: channel.channelType,
        isThreadedReply: isThreadedReply,
      ),
      _unreadCatchUpLimit,
    );

    final current = _latestObservedByChannel[channel.id] ?? 0;
    if (event.createdAt > current) {
      _latestObservedByChannel[channel.id] = event.createdAt;
    }
  }

  void clearObservedUnreadForChannel(String channelId) {
    _latestObservedByChannel.remove(channelId);
    _observedUnreadEventsByChannel.remove(channelId);
    state = state.whenData((channels) => List<Channel>.of(channels));
  }

  void clearObservedUnreadCoveredByRead(String channelId, int readAt) {
    final latest = _latestObservedByChannel[channelId];
    if (latest != null && latest <= readAt) {
      clearObservedUnreadForChannel(channelId);
    }
  }

  /// Backstop refresh that preserves existing state on transient failure.
  Future<void> _backstopRefresh() async {
    try {
      final sessionState = ref.read(relaySessionProvider);
      final prevChannels = state.value ?? const [];
      final prevLastMessage = {
        for (final c in prevChannels)
          if (c.lastMessageAt != null) c.id: c.lastMessageAt,
      };
      final channels = await _fetch(
        subscribeLive: sessionState.status == SessionStatus.connected,
        fetchLastMessage: false,
      );
      for (var i = 0; i < channels.length; i++) {
        final prev = prevLastMessage[channels[i].id];
        if (channels[i].lastMessageAt == null && prev != null) {
          channels[i] = channels[i].copyWith(lastMessageAt: prev);
        }
      }
      state = AsyncData(channels);
    } catch (error) {
      debugPrint('[ChannelsNotifier] backstop refresh failed: $error');
    }
  }

  Future<void> refresh() async {
    final sessionState = ref.read(relaySessionProvider);
    // Don't attempt to fetch when the session isn't connected — fetchHistory
    // would send REQs over an unauthenticated socket that either time out
    // (returning empty results) or get cancelled on disconnect, replacing the
    // cached channel list with [] or an error. Wait for `build()` to re-run
    // when the session transitions to connected.
    if (sessionState.status != SessionStatus.connected) return;
    _terminallyClosedChannelIds.clear();
    state = await AsyncValue.guard(() => _fetch(subscribeLive: true));
  }

  void _cancelPendingLiveSubscriptions() {
    for (final cancellation in _pendingSubscriptionCancellations.values) {
      if (!cancellation.isCompleted) cancellation.complete();
    }
    _pendingSubscriptionCancellations.clear();
  }

  void _clearLiveSubscriptions() {
    _subscriptionVersion++;
    _desiredLiveChannels = const [];
    _desiredLiveChannelIds = const {};
    _cancelPendingLiveSubscriptions();
    for (final subscription in _liveSubscriptionsByChannel.values) {
      subscription.unsubscribe();
    }
    _liveSubscriptionsByChannel.clear();
    _terminallyClosedChannelIds.clear();
    _subscriptionRelayBaseUrl = null;
    _backstopTimer?.cancel();
    _backstopTimer = null;
    _unreadCatchUpGeneration++;
    _unreadCatchUpChannelIds = const {};
  }
}

final channelsProvider = AsyncNotifierProvider<ChannelsNotifier, List<Channel>>(
  ChannelsNotifier.new,
);

final channelsLiveSubscriptionReadyTimeoutProvider = Provider<Duration>(
  (_) => liveSubscriptionReadyTimeout,
);
final channelsLiveSubscriptionDelayProvider = Provider<TaskDelay>(
  (_) => defaultTaskDelay,
);
