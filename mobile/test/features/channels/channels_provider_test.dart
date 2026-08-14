import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:buzz/features/channels/channel.dart';
import 'package:buzz/features/channels/channel_management_provider.dart';
import 'package:buzz/features/channels/channels_provider.dart';
import 'package:buzz/features/channels/channel_sync.dart';
import 'package:buzz/shared/relay/relay.dart';

/// Tests for [ChannelsNotifier] in the pure-Nostr world.
///
/// The provider performs a two-step WS query:
///   1. kind:39002 memberships tagged `#p:<my-pubkey>`
///   2. kind:39000 metadata for those channel ids
/// then layers per-channel live subscriptions on the `#h` tag.
///
/// Tests stub out the relay session by overriding [relaySessionProvider] with
/// a [_FakeRelaySession] that returns canned events from [fetchHistory] and
/// records [subscribe] calls so we can assert filter shapes and emit live
/// events on demand.
void main() {
  const myPk = 'me';

  test('chunks 1,565 channels into sixteen bounded HTTP requests', () {
    final chunks = chunkChannelsForLastMessageQuery([
      for (var i = 0; i < 1565; i++) _channel(_generatedChannelId(i)),
    ]);

    expect(chunks, hasLength(16));
    expect(chunks.take(15).every((chunk) => chunk.length == 100), isTrue);
    expect(chunks.last, hasLength(65));
  });

  test('chunks exact multiples without an empty trailing batch', () {
    final chunks = chunkChannelsForLastMessageQuery([
      for (var i = 0; i < 200; i++) _channel(_generatedChannelId(i)),
    ]);

    expect(chunks.map((chunk) => chunk.length), [100, 100]);
  });

  test('chunks aggregate last-message queries and isolates failures', () async {
    final channelIds = List.generate(201, _generatedChannelId);
    final session =
        _FakeRelaySession(
            memberships: [for (final id in channelIds) _membership(id, myPk)],
            metadata: [for (final id in channelIds) _meta(id: id, name: id)],
          )
          ..queryFailureCalls.add(2)
          ..queryEvents = [
            _message(channelIds.first, createdAt: 10),
            _message(channelIds[100], createdAt: 20),
            _message(channelIds.last, createdAt: 30),
          ];
    final container = _buildContainer(session: session);
    addTearDown(container.dispose);

    final channels = await container.read(channelsProvider.future);

    expect(session.queryFilterBatches.map((batch) => batch.length), [
      100,
      100,
      1,
    ]);
    expect(
      session.queryTimeouts.every(
        (timeout) => timeout <= const Duration(seconds: 8),
      ),
      isTrue,
    );
    expect(session.queryFilterBatches.expand((batch) => batch), hasLength(201));
    expect(
      channels
          .firstWhere((channel) => channel.id == channelIds.first)
          .lastMessageAt,
      DateTime.fromMillisecondsSinceEpoch(10000, isUtc: true),
    );
    expect(
      channels
          .firstWhere((channel) => channel.id == channelIds[100])
          .lastMessageAt,
      isNull,
    );
    expect(
      channels
          .firstWhere((channel) => channel.id == channelIds.last)
          .lastMessageAt,
      DateTime.fromMillisecondsSinceEpoch(30000, isUtc: true),
    );
  });

  test('catch-up recovers event missed before live REQ readiness', () async {
    final channelIds = List.generate(101, _generatedChannelId);
    final session = _FakeRelaySession(
      memberships: [for (final id in channelIds) _membership(id, myPk)],
      metadata: [for (final id in channelIds) _meta(id: id, name: id)],
    );
    session.pauseNextSubscribe();
    final container = _buildContainer(session: session);
    addTearDown(container.dispose);

    final channels = await container.read(channelsProvider.future);
    expect(
      channels
          .firstWhere((channel) => channel.id == channelIds.first)
          .lastMessageAt,
      isNull,
    );
    expect(session.activeSubscriptionCount, lessThan(101));

    final missedEvent = _message(channelIds.first, createdAt: 50);
    session.emit(missedEvent);
    session.unreadEvents = [missedEvent];
    session.resumePausedSubscribe();

    await _waitUntil(() => session.unreadCatchUpQueryCount > 0);
    await _waitUntil(
      () =>
          container
              .read(channelsProvider.notifier)
              .observedUnreadEventsByChannel[channelIds.first]
              ?.containsKey(missedEvent.id) ==
          true,
      attempts: 30000,
    );
    expect(
      container
          .read(channelsProvider)
          .value!
          .firstWhere((channel) => channel.id == channelIds.first)
          .lastMessageAt,
      DateTime.fromMillisecondsSinceEpoch(50000, isUtc: true),
    );
  });

  test(
    'small-account snapshot publishes without waiting for live EOSE',
    () async {
      final session = _FakeRelaySession(
        memberships: [_membership(_channelA, myPk)],
        metadata: [_meta(id: _channelA, name: 'general')],
      );
      session.pauseNextSubscribe();
      final container = _buildContainer(session: session);
      addTearDown(container.dispose);

      final channelFuture = container.read(channelsProvider.future);
      await session.nextSubscribeStarted;

      final channels = await channelFuture.timeout(const Duration(seconds: 1));
      expect(channels.single.id, _channelA);
      expect(session.activeChannels, isEmpty);

      session.resumePausedSubscribe();
      await _waitUntil(() => session.activeChannels.contains(_channelA));
    },
  );

  test('loaded refresh preserves newer live timestamp', () async {
    final channelIds = List.generate(101, _generatedChannelId);
    final session = _FakeRelaySession(
      memberships: [for (final id in channelIds) _membership(id, myPk)],
      metadata: [for (final id in channelIds) _meta(id: id, name: id)],
    )..queryEvents = [_message(channelIds.first, createdAt: 10)];
    final container = _buildContainer(session: session);
    addTearDown(container.dispose);

    await container.read(channelsProvider.future);
    session.pauseQueryCall(4);
    final refresh = container.read(channelsProvider.notifier).refresh();
    await session.nextPausedQueryStarted;
    session.emit(_message(channelIds.first, createdAt: 50));
    session.resumePausedQuery();
    await refresh;

    expect(
      container
          .read(channelsProvider)
          .value!
          .firstWhere((channel) => channel.id == channelIds.first)
          .lastMessageAt,
      DateTime.fromMillisecondsSinceEpoch(50000, isUtc: true),
    );
  });

  test('stale unread fallback stops before its next wave', () async {
    final channelIds = List.generate(9, _generatedChannelId);
    final session = _FakeRelaySession(
      memberships: [for (final id in channelIds) _membership(id, myPk)],
      metadata: [for (final id in channelIds) _meta(id: id, name: id)],
    )..queryFailureCalls.add(2);
    session.pauseNextUnreadCatchUp();
    final container = _buildContainer(session: session);
    addTearDown(container.dispose);

    await container.read(channelsProvider.future);
    await session.nextUnreadCatchUpStarted;
    expect(session.unreadFallbackFetchCount, 4);

    session.setStatus(SessionStatus.disconnected);
    session.resumePausedUnreadCatchUp();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(session.unreadFallbackFetchCount, 4);
  });

  test('unchanged refresh does not restart unread catch-up', () async {
    final session = _FakeRelaySession(
      memberships: [_membership(_channelA, myPk)],
      metadata: [_meta(id: _channelA, name: 'general')],
    );
    final container = _buildContainer(session: session);
    addTearDown(container.dispose);

    await container.read(channelsProvider.future);
    await _waitUntil(() => session.unreadCatchUpQueryCount == 1);
    await container.read(channelsProvider.notifier).refresh();
    await Future<void>.delayed(Duration.zero);

    expect(session.unreadCatchUpQueryCount, 1);
  });

  test(
    'disconnect discards stale catch-up and reconnect restarts it',
    () async {
      final session = _FakeRelaySession(
        memberships: [_membership(_channelA, myPk)],
        metadata: [_meta(id: _channelA, name: 'general')],
      )..unreadEvents = [_message(_channelA, createdAt: 20)];
      session.pauseNextUnreadCatchUp();
      final container = _buildContainer(session: session);
      addTearDown(container.dispose);

      await container.read(channelsProvider.future);
      await session.nextUnreadCatchUpStarted;

      session.setStatus(SessionStatus.disconnected);
      session.resumePausedUnreadCatchUp();
      await Future<void>.delayed(Duration.zero);
      expect(
        container
            .read(channelsProvider.notifier)
            .observedUnreadEventsByChannel[_channelA],
        isNull,
      );

      session.setStatus(SessionStatus.connected);
      await _waitUntil(() => session.unreadCatchUpQueryCount == 2);
      await _waitUntil(
        () =>
            container
                .read(channelsProvider.notifier)
                .observedUnreadEventsByChannel[_channelA]
                ?.isNotEmpty ==
            true,
      );
    },
  );

  test('builds one bounded last-message filter per channel type', () {
    final filters = buildChannelLastMessageFilters([
      _channel(_channelA),
      _channel(_channelB, channelType: 'dm'),
    ]);

    expect(filters, hasLength(2));
    expect(filters[0].tags['#h'], [_channelA]);
    expect(filters[0].limit, 20);
    expect(filters[1].tags['#h'], [_channelB]);
    expect(filters[1].limit, 1);
  });

  test('maps newest qualifying last messages and preserves DM semantics', () {
    final channels = [
      _channel(_channelA),
      _channel(_channelB, channelType: 'dm'),
    ];
    final result = resolveChannelLastMessages(channels, [
      _message(_channelA, createdAt: 10, pubkey: myPk),
      _message(_channelA, createdAt: 20),
      _message(_channelA, createdAt: 15),
      _message(_channelB, createdAt: 30, pubkey: myPk),
      _message(_channelD, createdAt: 40),
    ], myPk: myPk);

    expect(result, {_channelA: 20, _channelB: 30});
  });

  test('paced tasks enforce concurrency and requested start spacing', () async {
    var active = 0;
    var maxActive = 0;
    var created = 0;
    final delays = <Duration>[];
    final completions = List.generate(12, (_) => Completer<void>());
    final tasks = [
      for (var i = 0; i < completions.length; i++)
        () async {
          created++;
          active++;
          maxActive = max(maxActive, active);
          await completions[i].future;
          active--;
        },
    ];

    final run = runPacedTasks(
      tasks,
      maxConcurrent: 4,
      startInterval: const Duration(milliseconds: 125),
      isCancelled: () => false,
      delay: (duration) async {
        delays.add(duration);
      },
    );
    await _waitUntil(() => created == 4);

    expect(maxActive, 4);
    expect(delays, everyElement(const Duration(milliseconds: 125)));
    expect(delays, hasLength(3));

    for (final completion in completions) {
      completion.complete();
    }
    await run;
    expect(maxActive, 4);
    expect(created, 12);
    expect(delays, hasLength(11));
  });

  test('readiness timeout cancels the pending subscription', () async {
    final cancellation = Completer<void>();
    Duration? armedFor;
    void Function()? fire;
    final timer = _TestTimer();
    final subscription = subscribeWhenReadyWithTimeout(
      (cancelled) async {
        await cancelled;
        throw const RelaySubscriptionCancelledException();
      },
      cancellation,
      timerFactory: (duration, callback) {
        armedFor = duration;
        fire = callback;
        return timer;
      },
    );

    expect(armedFor, liveSubscriptionReadyTimeout);
    expect(cancellation.isCompleted, isFalse);
    fire!();
    await expectLater(subscription, throwsA(isA<TimeoutException>()));
    expect(timer.isActive, isFalse);
  });

  test(
    'paced tasks are lazy, bounded, failure-isolated, and cancellable',
    () async {
      var active = 0;
      var maxActive = 0;
      var created = 0;
      var errors = 0;
      var cancelled = false;
      final permits = <Completer<void>>[];
      final completions = List.generate(6, (_) => Completer<void>());
      final tasks = [
        for (var i = 0; i < completions.length; i++)
          () async {
            created++;
            active++;
            maxActive = max(maxActive, active);
            if (i == 1) {
              active--;
              throw Exception('isolated');
            }
            await completions[i].future;
            active--;
          },
      ];

      final run = runPacedTasks(
        tasks,
        maxConcurrent: 4,
        startInterval: const Duration(milliseconds: 125),
        isCancelled: () => cancelled,
        delay: (_) {
          if (cancelled) return Future.value();
          final permit = Completer<void>();
          permits.add(permit);
          return permit.future;
        },
        onError: (_) => errors++,
      );
      await Future<void>.delayed(Duration.zero);
      expect(created, 1);
      expect(permits, hasLength(1));

      for (var expectedCreated = 2; expectedCreated <= 4; expectedCreated++) {
        permits.removeAt(0).complete();
        await Future<void>.delayed(Duration.zero);
        expect(created, expectedCreated);
        if (expectedCreated < 4) expect(permits, hasLength(1));
      }
      expect(maxActive, 3);

      cancelled = true;
      for (final completion in completions) {
        if (!completion.isCompleted) completion.complete();
      }
      for (final permit in permits) {
        if (!permit.isCompleted) permit.complete();
      }
      await run;
      expect(created, 4);
      expect(errors, 1);
    },
  );

  test(
    'seeds members from the channel-list snapshot during reconnect',
    () async {
      final session = _FakeRelaySession(
        memberships: [_membership(_channelA, myPk, additionalPubkey: 'alice')],
        metadata: [_meta(id: _channelA, name: 'general')],
      );
      final container = _buildContainer(session: session);
      addTearDown(container.dispose);

      await container.read(channelsProvider.future);
      final memberQueryCount = session.historyFilters
          .where(
            (filter) =>
                filter.kinds.contains(39002) && filter.tags['#d'] != null,
          )
          .length;

      session.setStatus(SessionStatus.reconnecting);
      final members = await container.read(
        channelMembersProvider(_channelA).future,
      );

      expect(members.map((member) => member.pubkey), [myPk, 'alice']);
      expect(
        session.historyFilters
            .where(
              (filter) =>
                  filter.kinds.contains(39002) && filter.tags['#d'] != null,
            )
            .length,
        memberQueryCount,
      );
    },
  );

  test(
    'subscribes per-channel with #h tags (only joined, non-archived)',
    () async {
      final session = _FakeRelaySession(
        memberships: [
          _membership(_channelA, myPk),
          _membership(_channelB, myPk),
          _membership(_channelD, myPk),
        ],
        metadata: [
          _meta(id: _channelA, name: 'general'),
          _meta(id: _channelB, name: 'random'),
          // channelD metadata missing -> won't appear in channel list
        ],
      );
      final container = _buildContainer(session: session);
      addTearDown(container.dispose);

      await container.read(channelsProvider.future);
      await _waitUntil(() => session.activeSubscriptionCount == 2);

      // One subscription per joined, non-archived channel.
      expect(session.subscribeFilters, hasLength(2));
      expect(
        session.subscribeFilters.map((f) => f.tags['#h']?.single).toSet(),
        {_channelA, _channelB},
      );
      for (final filter in session.subscribeFilters) {
        expect(filter.kinds, EventKind.channelEventKinds);
        expect(filter.limit, 0);
      }
    },
  );

  test('retains channel-list member snapshots for immediate reuse', () async {
    final joinedAt = DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true);
    final session = _FakeRelaySession(
      memberships: [_membership(_channelA, myPk, additionalPubkey: 'alice')],
      metadata: [_meta(id: _channelA, name: 'general')],
    );
    final container = _buildContainer(session: session);
    addTearDown(container.dispose);

    await container.read(channelsProvider.future);
    final members = container
        .read(channelsProvider.notifier)
        .cachedMembersForChannel(_channelA);

    expect(members, hasLength(2));
    expect(members.map((member) => member.pubkey), [myPk, 'alice']);
    expect(members.every((member) => member.joinedAt == joinedAt), isTrue);
  });

  test(
    'refreshing an unchanged channel set issues zero new live REQs',
    () async {
      final session = _FakeRelaySession(
        memberships: [
          _membership(_channelA, myPk),
          _membership(_channelB, myPk),
        ],
        metadata: [
          _meta(id: _channelA, name: 'general'),
          _meta(id: _channelB, name: 'random'),
        ],
      );
      final container = _buildContainer(session: session);
      addTearDown(container.dispose);

      await container.read(channelsProvider.future);
      await _waitUntil(() => session.activeSubscriptionCount == 2);
      final initialSubscribeCount = session.totalSubscribeCount;

      await container.read(channelsProvider.notifier).refresh();

      expect(session.totalSubscribeCount, initialSubscribeCount);
      expect(session.unsubscribeCount, 0);
      expect(session.subscribeFilters, hasLength(2));
    },
  );

  test(
    'never-EOSE workers time out and later channels still catch up',
    () async {
      final channelIds = List.generate(6, _generatedChannelId);
      final session = _FakeRelaySession(
        memberships: [for (final id in channelIds) _membership(id, myPk)],
        metadata: [for (final id in channelIds) _meta(id: id, name: id)],
      )..neverReadyChannelIds.addAll(channelIds.take(4));
      final missedEvent = _message(channelIds.last, createdAt: 50);
      session.unreadEvents = [missedEvent];
      final container = _buildContainer(
        session: session,
        liveReadyTimeout: Duration.zero,
      );
      addTearDown(container.dispose);

      await container.read(channelsProvider.future);
      await _waitUntil(
        () =>
            session.activeChannels.containsAll(channelIds.skip(4)) &&
            container
                    .read(channelsProvider.notifier)
                    .observedUnreadEventsByChannel[channelIds.last]
                    ?.containsKey(missedEvent.id) ==
                true,
        attempts: 30000,
      );

      expect(session.activeChannels, containsAll(channelIds.skip(4)));
      expect(session.totalSubscribeCount, channelIds.length);
    },
  );

  test(
    'terminal live failure catches up only ready channels and retries gap',
    () async {
      final session = _FakeRelaySession(
        memberships: [
          _membership(_channelA, myPk),
          _membership(_channelB, myPk),
        ],
        metadata: [
          _meta(id: _channelA, name: 'general'),
          _meta(id: _channelB, name: 'random'),
        ],
      )..subscribeFailuresByChannel[_channelA] = 1;
      final container = _buildContainer(session: session);
      addTearDown(container.dispose);

      await container.read(channelsProvider.future);
      await _waitUntil(() => session.unreadCatchUpQueryCount == 1);
      expect(session.activeChannels, {_channelB});
      expect(
        session.queryFilterBatches
            .expand((filters) => filters)
            .where((filter) => filter.since != null)
            .map((filter) => filter.tags['#h']!.single),
        [_channelB],
      );

      final missedEvent = _message(_channelA, createdAt: 50);
      session.unreadEvents = [missedEvent];
      await container.read(channelsProvider.notifier).refresh();

      await _waitUntil(
        () => session.queryFilterBatches
            .expand((filters) => filters)
            .any(
              (filter) =>
                  filter.since != null &&
                  filter.tags['#h']?.single == _channelA,
            ),
        attempts: 30000,
      );
      expect(session.activeChannels, {_channelA, _channelB});
      expect(
        container
            .read(channelsProvider.notifier)
            .observedUnreadEventsByChannel[_channelA]
            ?.containsKey(missedEvent.id),
        isTrue,
      );
      expect(
        container
            .read(channelsProvider)
            .value!
            .firstWhere((channel) => channel.id == _channelA)
            .lastMessageAt,
        DateTime.fromMillisecondsSinceEpoch(50000, isUtc: true),
      );
    },
  );

  test(
    'post-ready terminal close stays quarantined until explicit refresh',
    () async {
      final session = _FakeRelaySession(
        memberships: [_membership(_channelA, myPk)],
        metadata: [_meta(id: _channelA, name: 'general')],
      );
      final container = _buildContainer(session: session);
      addTearDown(container.dispose);

      await container.read(channelsProvider.future);
      await _waitUntil(() => session.unreadCatchUpQueryCount == 1);
      expect(session.activeChannels, {_channelA});

      session.terminallyClose(_channelA);
      expect(session.activeChannels, isEmpty);
      final subscribeCountAfterClose = session.totalSubscribeCount;
      final missedEvent = _message(_channelA, createdAt: 50);
      session.unreadEvents = [missedEvent];

      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(session.totalSubscribeCount, subscribeCountAfterClose);
      expect(session.activeChannels, isEmpty);

      await container.read(channelsProvider.notifier).refresh();

      await _waitUntil(
        () =>
            session.activeChannels.contains(_channelA) &&
            container
                    .read(channelsProvider.notifier)
                    .observedUnreadEventsByChannel[_channelA]
                    ?.containsKey(missedEvent.id) ==
                true,
        attempts: 30000,
      );
      expect(
        container
            .read(channelsProvider)
            .value!
            .firstWhere((channel) => channel.id == _channelA)
            .lastMessageAt,
        DateTime.fromMillisecondsSinceEpoch(50000, isUtc: true),
      );
    },
  );

  test(
    'live subscription diff only removes and adds changed channels',
    () async {
      final session = _FakeRelaySession(
        memberships: [
          _membership(_channelA, myPk),
          _membership(_channelB, myPk),
        ],
        metadata: [
          _meta(id: _channelA, name: 'general'),
          _meta(id: _channelB, name: 'random'),
        ],
      );
      final container = _buildContainer(session: session);
      addTearDown(container.dispose);

      await container.read(channelsProvider.future);
      session.memberships = [
        _membership(_channelB, myPk),
        _membership(_channelD, myPk),
      ];
      session.metadata = [
        _meta(id: _channelB, name: 'random'),
        _meta(id: _channelD, name: 'support'),
      ];

      await container.read(channelsProvider.notifier).refresh();

      expect(session.totalSubscribeCount, 3);
      expect(session.unsubscribeCount, 1);
      expect(
        session.subscribeFilters
            .map((filter) => filter.tags['#h']!.single)
            .toSet(),
        {_channelB, _channelD},
      );
    },
  );

  test(
    'empty channel refresh removes every retained live subscription',
    () async {
      final session = _FakeRelaySession(
        memberships: [
          _membership(_channelA, myPk),
          _membership(_channelB, myPk),
        ],
        metadata: [
          _meta(id: _channelA, name: 'general'),
          _meta(id: _channelB, name: 'random'),
        ],
      );
      final container = _buildContainer(session: session);
      addTearDown(container.dispose);

      await container.read(channelsProvider.future);
      session.memberships = [];
      session.metadata = [];

      await container.read(channelsProvider.notifier).refresh();

      expect(session.activeChannels, isEmpty);
      expect(session.activeSubscriptionCount, 0);
      expect(session.unsubscribeCount, 2);
    },
  );

  test(
    'overlapping refreshes retain one live subscription per desired channel',
    () async {
      final session = _FakeRelaySession(
        memberships: [
          _membership(_channelA, myPk),
          _membership(_channelB, myPk),
        ],
        metadata: [
          _meta(id: _channelA, name: 'general'),
          _meta(id: _channelB, name: 'random'),
        ],
      );
      final container = _buildContainer(session: session);
      addTearDown(container.dispose);

      await container.read(channelsProvider.future);
      session.pauseNextSubscribe();
      session.memberships = [
        _membership(_channelA, myPk),
        _membership(_channelB, myPk),
        _membership(_channelD, myPk),
      ];
      session.metadata = [
        _meta(id: _channelA, name: 'general'),
        _meta(id: _channelB, name: 'random'),
        _meta(id: _channelD, name: 'support'),
      ];

      final firstRefresh = container.read(channelsProvider.notifier).refresh();
      await session.nextSubscribeStarted;
      final secondRefresh = container.read(channelsProvider.notifier).refresh();
      session.resumePausedSubscribe();
      await Future.wait([firstRefresh, secondRefresh]);

      expect(session.activeChannels, {_channelA, _channelB, _channelD});
      expect(session.activeSubscriptionCount, 3);
    },
  );

  test(
    'community switch replaces retained live subscriptions on the new relay',
    () async {
      final session = _FakeRelaySession(
        memberships: [_membership(_channelA, myPk)],
        metadata: [_meta(id: _channelA, name: 'general')],
      );
      final container = _buildContainer(session: session);
      addTearDown(container.dispose);

      await container.read(channelsProvider.future);
      expect(session.activeChannels, {_channelA});

      session.setStatus(SessionStatus.disconnected);
      session.memberships = [_membership(_channelB, myPk)];
      session.metadata = [_meta(id: _channelB, name: 'random')];
      container
          .read(relayConfigProvider.notifier)
          .update(baseUrl: 'https://new-community.example');
      await Future<void>.delayed(Duration.zero);
      session.setStatus(SessionStatus.connected);
      await container.read(channelsProvider.future);
      await _waitUntil(
        () =>
            session.activeChannels.length == 1 &&
            session.activeChannels.contains(_channelB),
      );

      expect(session.activeChannels, {_channelB});
      expect(session.activeSubscriptionCount, 1);
      expect(session.unsubscribeCount, 1);
    },
  );

  test('live channel events update channel lastMessageAt', () async {
    final session = _FakeRelaySession(
      memberships: [_membership(_channelA, myPk)],
      metadata: [_meta(id: _channelA, name: 'general', createdAt: 10)],
    );
    final container = _buildContainer(session: session);
    addTearDown(container.dispose);

    await container.read(channelsProvider.future);

    // Emit a live message event on channelA.
    session.emit(
      NostrEvent(
        id: 'event-1',
        pubkey: 'alice',
        createdAt: 20,
        kind: EventKind.streamMessageV2,
        tags: const [
          ['h', _channelA],
        ],
        content: 'new message',
        sig: 'sig',
      ),
    );

    final channels = container.read(channelsProvider).value!;
    expect(channels.single.lastMessageAt?.millisecondsSinceEpoch, 20 * 1000);
  });

  test(
    'loads all channel timestamps through one batched relay query',
    () async {
      final session = _FakeRelaySession(
        memberships: [
          _membership(_channelA, myPk),
          _membership(_channelB, myPk),
        ],
        metadata: [
          _meta(id: _channelA, name: 'general'),
          _meta(id: _channelB, name: 'direct', channelType: 'dm'),
        ],
        recentMessages: const [
          NostrEvent(
            id: 'stream-message',
            pubkey: 'alice',
            createdAt: 30,
            kind: EventKind.streamMessageV2,
            tags: [
              ['h', _channelA],
            ],
            content: 'hello',
            sig: 'sig',
          ),
          NostrEvent(
            id: 'dm-message',
            pubkey: 'alice',
            createdAt: 40,
            kind: 9,
            tags: [
              ['h', _channelB],
            ],
            content: 'hello privately',
            sig: 'sig',
          ),
        ],
      );
      final container = _buildContainer(session: session);
      addTearDown(container.dispose);

      final channels = await container.read(channelsProvider.future);

      await _waitUntil(() => session.queryBatches.length == 2);
      expect(session.queryBatches, hasLength(2));
      expect(session.queryBatches.first, hasLength(2));
      expect(
        session.queryBatches.first
            .map((filter) => filter.tags['#h']!.single)
            .toSet(),
        {_channelA, _channelB},
      );
      expect(session.queryBatches.last, hasLength(2));
      expect(
        session.queryBatches.last.every(
          (filter) => filter.limit == 1000 && filter.since == 0,
        ),
        isTrue,
      );
      expect(
        session.historyFilters.where((filter) {
          final kinds = filter.kinds.toSet();
          return kinds.length == EventKind.channelMessageEventKinds.length &&
              kinds.containsAll(EventKind.channelMessageEventKinds);
        }),
        isEmpty,
      );
      expect(
        channels.firstWhere((channel) => channel.id == _channelA).lastMessageAt,
        DateTime.fromMillisecondsSinceEpoch(30 * 1000, isUtc: true),
      );
      expect(
        channels.firstWhere((channel) => channel.id == _channelB).lastMessageAt,
        DateTime.fromMillisecondsSinceEpoch(40 * 1000, isUtc: true),
      );
    },
  );

  test('ephemeral (TTL) channels appear in the list', () async {
    // Regression: previously the provider unconditionally dropped any channel
    // with a `ttl` tag, which made TTL channels invisible on iOS even when the
    // user was a member. They should be included so the existing
    // `_EphemeralBadge` UI in `channels_page.dart` can render them.
    final session = _FakeRelaySession(
      memberships: [_membership(_channelA, myPk), _membership(_channelB, myPk)],
      metadata: [
        _meta(id: _channelA, name: 'general'),
        _meta(
          id: _channelB,
          name: 'agent-creation-deep-dive',
          ttlSeconds: 86400,
        ),
      ],
    );
    final container = _buildContainer(session: session);
    addTearDown(container.dispose);

    final channels = await container.read(channelsProvider.future);

    expect(
      channels.map((c) => c.name),
      containsAll(['general', 'agent-creation-deep-dive']),
    );
    final ephemeral = channels.firstWhere(
      (c) => c.name == 'agent-creation-deep-dive',
    );
    expect(ephemeral.isEphemeral, isTrue);
    expect(ephemeral.ttlSeconds, 86400);
  });

  test('hidden DMs are filtered from the channel list', () async {
    final session = _FakeRelaySession(
      memberships: [_membership(_channelA, myPk), _membership(_channelB, myPk)],
      metadata: [
        _meta(id: _channelA, name: 'Alice', channelType: 'dm'),
        _meta(id: _channelB, name: 'Bob', channelType: 'dm'),
      ],
      hiddenDmEvents: [
        _hiddenDms([_channelA], pubkey: myPk),
      ],
    );
    final container = _buildContainer(session: session);
    addTearDown(container.dispose);

    final channels = await container.read(channelsProvider.future);

    expect(channels.map((c) => c.id), [_channelB]);
    expect(
      session.historyFilters.any(
        (filter) =>
            filter.kinds.contains(EventKind.dmVisibility) &&
            filter.tags['#p']?.single == myPk,
      ),
      isTrue,
    );
  });

  test(
    'archived kind:39000 metadata sets Channel.isArchived (covers TTL auto-archive)',
    () async {
      // The relay's TTL reaper auto-archives expired ephemeral channels and
      // republishes kind:39000 with `["archived", "true"]`. The Channel needs
      // `archivedAt != null` so the `_SliverChannelsList` filter
      // (`!channel.isArchived`) hides it from the sidebar after expiry.
      // Previously the mobile parser ignored the `archived` tag, so expired
      // TTL channels would have stayed visible after the `!isEphemeral` guard
      // was removed.
      final session = _FakeRelaySession(
        memberships: [
          _membership(_channelA, myPk),
          _membership(_channelB, myPk),
        ],
        metadata: [
          _meta(id: _channelA, name: 'active'),
          _meta(
            id: _channelB,
            name: 'expired-ttl',
            ttlSeconds: 86400,
            archived: true,
          ),
        ],
      );
      final container = _buildContainer(session: session);
      addTearDown(container.dispose);

      final channels = await container.read(channelsProvider.future);
      final expired = channels.firstWhere((c) => c.name == 'expired-ttl');
      expect(expired.isArchived, isTrue);
      expect(expired.isEphemeral, isTrue);
      // The active channel must not be flagged archived.
      final active = channels.firstWhere((c) => c.name == 'active');
      expect(active.isArchived, isFalse);
    },
  );

  test(
    'archive transition invalidates cached channelDetailsProvider',
    () async {
      // Codex review v2 caught: if a TTL channel is opened (caching its
      // ChannelDetails) and then the reaper archives it, the cached details
      // — built from the pre-archive kind:39000 — would clobber the newer
      // archivedAt set on the base Channel during `mergeDetails`. We invalidate
      // the details provider when the archived state flips so the next
      // mergeDetails sees fresh data.
      final session = _FakeRelaySession(
        memberships: [_membership(_channelA, myPk)],
        metadata: [_meta(id: _channelA, name: 'active')],
      );
      final container = _buildContainer(session: session);
      addTearDown(container.dispose);

      // Initial load.
      final initial = await container.read(channelsProvider.future);
      expect(initial.single.isArchived, isFalse);

      // Prime the detail cache.
      final detailsFiltersBefore = session.historyFilters
          .where((f) => f.kinds.contains(39000) && f.tags['#d'] != null)
          .length;
      await container.read(channelDetailsProvider(_channelA).future);
      final detailsFetchesAfterPrime =
          session.historyFilters
              .where((f) => f.kinds.contains(39000) && f.tags['#d'] != null)
              .length -
          detailsFiltersBefore;
      expect(detailsFetchesAfterPrime, 1);

      // Simulate the reaper auto-archiving the channel by swapping the
      // metadata the fake returns, then refreshing the channels provider.
      session.metadata
        ..clear()
        ..add(_meta(id: _channelA, name: 'active', archived: true));
      await container.read(channelsProvider.notifier).refresh();
      final refreshed = container.read(channelsProvider).value!;
      expect(refreshed.single.isArchived, isTrue);

      // Take a fresh baseline AFTER the refresh — the refresh itself issues a
      // `kinds:[39000], #d:[id]` query as part of channel metadata refetch and
      // we must not count that toward our invalidation assertion. Only the
      // fetch triggered by the second `channelDetailsProvider` read should be
      // attributed to invalidation.
      final detailsFiltersAfterRefresh = session.historyFilters
          .where((f) => f.kinds.contains(39000) && f.tags['#d'] != null)
          .length;

      // Reading the details provider again must trigger a fresh fetch — proving
      // the prior cache was invalidated by the archive transition. Without
      // invalidation, Riverpod would return the cached pre-archive details and
      // no new `kinds:[39000], #d:[id]` filter would be sent.
      await container.read(channelDetailsProvider(_channelA).future);
      final detailsFetchesFromInvalidation =
          session.historyFilters
              .where((f) => f.kinds.contains(39000) && f.tags['#d'] != null)
              .length -
          detailsFiltersAfterRefresh;
      expect(detailsFetchesFromInvalidation, greaterThan(0));
    },
  );

  test(
    'keeps cached channels and live subscriptions during reconnect',
    () async {
      final session = _FakeRelaySession(
        memberships: [_membership(_channelA, myPk)],
        metadata: [_meta(id: _channelA, name: 'general')],
      );
      final container = _buildContainer(session: session);
      addTearDown(container.dispose);

      final initial = await container.read(channelsProvider.future);
      expect(initial.single.name, 'general');
      await _waitUntil(() => session.activeSubscriptionCount == 1);
      expect(session.subscribeFilters, hasLength(1));

      session.setStatus(SessionStatus.reconnecting);
      final reconnecting = await container.read(channelsProvider.future);

      expect(reconnecting.single.name, 'general');
      expect(session.subscribeFilters, hasLength(1));
      expect(session.unsubscribeCount, 0);
    },
  );

  test(
    'refreshes cached channels after a disconnected community switch',
    () async {
      final session = _FakeRelaySession(
        memberships: [_membership(_channelA, myPk)],
        metadata: [_meta(id: _channelA, name: 'general')],
      );
      final container = _buildContainer(session: session);
      addTearDown(container.dispose);

      expect(
        (await container.read(channelsProvider.future)).single.name,
        'general',
      );

      session.setStatus(SessionStatus.disconnected);
      session.memberships = [_membership(_channelB, myPk)];
      session.metadata = [_meta(id: _channelB, name: 'random')];
      container
          .read(relayConfigProvider.notifier)
          .update(baseUrl: 'https://new-community.example');
      await Future<void>.delayed(Duration.zero);
      expect(container.read(channelsProvider).value?.single.name, 'general');

      session.setStatus(SessionStatus.connected);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(channelsProvider).value?.single.name, 'random');
    },
  );

  test('recovers an initial fetch failure after reconnecting', () async {
    final session = _FakeRelaySession(
      memberships: [_membership(_channelA, myPk)],
      metadata: [_meta(id: _channelA, name: 'general')],
      membershipFailures: 1,
    );
    final container = _buildContainer(session: session);
    addTearDown(container.dispose);

    await expectLater(container.read(channelsProvider.future), throwsException);

    session.setStatus(SessionStatus.reconnecting);
    session.setStatus(SessionStatus.connected);
    await Future<void>.delayed(Duration.zero);

    final recovered = await container.read(channelsProvider.future);
    expect(recovered.single.name, 'general');
  });

  test(
    'preserves a successfully loaded empty list while disconnected',
    () async {
      final session = _FakeRelaySession(memberships: [], metadata: []);
      final container = _buildContainer(session: session);
      addTearDown(container.dispose);

      expect(await container.read(channelsProvider.future), isEmpty);
      final fetchCount = session.historyFilters.length;

      session.setStatus(SessionStatus.reconnecting);
      expect(await container.read(channelsProvider.future), isEmpty);
      expect(session.historyFilters, hasLength(fetchCount));
    },
  );

  test('initial fetch issues membership + metadata queries', () async {
    final session = _FakeRelaySession(
      memberships: [_membership(_channelA, myPk)],
      metadata: [_meta(id: _channelA, name: 'general')],
    );
    final container = _buildContainer(session: session);
    addTearDown(container.dispose);

    await container.read(channelsProvider.future);

    // Two history fetches for channel loading, plus one per non-DM channel
    // for high-priority event backfill.
    expect(session.historyFilters.length, greaterThanOrEqualTo(2));
    expect(session.historyFilters[0].kinds, [39002]);
    expect(session.historyFilters[0].tags['#p'], [myPk]);
    expect(session.historyFilters[1].kinds, [39000]);
    expect(session.historyFilters[1].tags['#d'], [_channelA]);

    // And one live subscription on the resulting channel.
    expect(session.subscribeFilters, hasLength(1));
  });
}

const _channelA = '11111111-1111-4111-8111-111111111111';
const _channelB = '22222222-2222-4222-8222-222222222222';
const _channelD = '44444444-4444-4444-8444-444444444444';

String _generatedChannelId(int index) {
  final suffix = index.toRadixString(16).padLeft(12, '0');
  return 'aaaaaaaa-aaaa-4aaa-8aaa-$suffix';
}

NostrEvent _message(
  String channelId, {
  required int createdAt,
  String pubkey = 'alice',
}) => NostrEvent(
  id: 'message-$channelId-$createdAt',
  pubkey: pubkey,
  createdAt: createdAt,
  kind: EventKind.streamMessageV2,
  tags: [
    ['h', channelId],
  ],
  content: 'message',
  sig: 'sig',
);

Channel _channel(String id, {String channelType = 'stream'}) => Channel(
  id: id,
  name: id,
  channelType: channelType,
  visibility: 'open',
  description: '',
  createdBy: 'creator',
  createdAt: DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
  memberCount: 1,
  isMember: true,
);

/// Build a kind:39002 membership event tagged with the channel id and member.
NostrEvent _membership(
  String channelId,
  String pubkey, {
  String? additionalPubkey,
}) => NostrEvent(
  id: 'mem-$channelId',
  pubkey: 'creator',
  createdAt: 1,
  kind: 39002,
  tags: [
    ['d', channelId],
    ['p', pubkey],
    if (additionalPubkey != null) ['p', additionalPubkey],
  ],
  content: '',
  sig: 'sig',
);

NostrEvent _hiddenDms(List<String> channelIds, {required String pubkey}) =>
    NostrEvent(
      id: 'hidden-${channelIds.join('-')}',
      pubkey: 'relay',
      createdAt: 2,
      kind: EventKind.dmVisibility,
      tags: [
        ['d', pubkey],
        ['p', pubkey],
        for (final channelId in channelIds) ['h', channelId],
      ],
      content: '',
      sig: 'sig',
    );

/// Build a kind:39000 channel metadata event.
NostrEvent _meta({
  required String id,
  required String name,
  String channelType = 'stream',
  int createdAt = 1,
  int? ttlSeconds,
  bool archived = false,
}) => NostrEvent(
  id: 'meta-$id',
  pubkey: 'creator',
  createdAt: createdAt,
  kind: 39000,
  tags: [
    ['d', id],
    ['name', name],
    ['t', channelType],
    ['public'],
    if (ttlSeconds != null) ['ttl', '$ttlSeconds'],
    if (archived) ['archived', 'true'],
  ],
  content: '',
  sig: 'sig',
);

ProviderContainer _buildContainer({
  required _FakeRelaySession session,
  Duration liveReadyTimeout = liveSubscriptionReadyTimeout,
}) {
  return ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      appLifecycleProvider.overrideWith(() => _FakeAppLifecycleNotifier()),
      relaySessionProvider.overrideWith(() => session),
      channelsLiveSubscriptionReadyTimeoutProvider.overrideWithValue(
        liveReadyTimeout,
      ),
      channelsLiveSubscriptionDelayProvider.overrideWithValue(
        (_) => Future<void>.value(),
      ),
      myPubkeyProvider.overrideWithValue('me'),
    ],
  );
}

Future<void> _waitUntil(bool Function() predicate, {int attempts = 100}) async {
  for (var i = 0; i < attempts; i++) {
    if (predicate()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Timed out waiting for asynchronous provider work');
}

/// Fake [RelaySessionNotifier] that returns canned events from [fetchHistory]
/// and records subscribe calls.
class _FakeRelaySession extends RelaySessionNotifier {
  _FakeRelaySession({
    required this.memberships,
    required this.metadata,
    this.hiddenDmEvents = const [],
    this.recentMessages = const [],
    this.membershipFailures = 0,
  });

  List<NostrEvent> memberships;
  List<NostrEvent> metadata;
  final List<NostrEvent> hiddenDmEvents;
  final List<NostrEvent> recentMessages;
  int membershipFailures;

  final List<NostrFilter> historyFilters = [];
  final List<List<NostrFilter>> queryBatches = [];
  final List<List<NostrFilter>> queryFilterBatches = [];
  final List<Duration> queryTimeouts = [];
  final Set<int> queryFailureCalls = {};
  final Map<String, int> subscribeFailuresByChannel = {};
  final Set<String> neverReadyChannelIds = {};
  List<NostrEvent> queryEvents = [];
  int? _pausedQueryCall;
  Completer<void>? _pausedQuery;
  Completer<void>? _pausedQueryStarted;
  final List<NostrFilter> subscribeFilters = [];
  final Map<
    int,
    (NostrFilter, void Function(NostrEvent), void Function(String message)?)
  >
  _subscriptions = {};
  int _nextSubscriptionKey = 0;
  Completer<void>? _pausedSubscribe;
  Completer<void>? _subscribeStarted;
  Completer<void>? _pausedUnreadCatchUp;
  Completer<void>? _unreadCatchUpStarted;
  List<NostrEvent> unreadEvents = [];
  int unsubscribeCount = 0;
  int totalSubscribeCount = 0;

  int get unreadFallbackFetchCount => historyFilters
      .where(
        (filter) =>
            filter.tags['#h']?.length == 1 &&
            filter.since != null &&
            filter.kinds.length == EventKind.channelMessageEventKinds.length &&
            filter.kinds.every(EventKind.channelMessageEventKinds.contains),
      )
      .length;

  int get unreadCatchUpQueryCount => queryFilterBatches
      .expand((filters) => filters)
      .where(
        (filter) =>
            filter.tags['#h']?.length == 1 &&
            filter.since != null &&
            filter.kinds.length == EventKind.channelMessageEventKinds.length &&
            filter.kinds.every(EventKind.channelMessageEventKinds.contains),
      )
      .length;

  Set<String> get activeChannels => {
    for (final (filter, _, _) in _subscriptions.values)
      ?filter.tags['#h']?.single,
  };

  int get activeSubscriptionCount => _subscriptions.length;

  Future<void> get nextSubscribeStarted async {
    final started = _subscribeStarted;
    if (started == null) {
      throw StateError('No paused subscription is pending');
    }
    await started.future;
  }

  void pauseNextSubscribe() {
    if (_pausedSubscribe != null) {
      throw StateError('A subscription is already paused');
    }
    _pausedSubscribe = Completer<void>();
    _subscribeStarted = Completer<void>();
  }

  void resumePausedSubscribe() {
    final paused = _pausedSubscribe;
    if (paused == null) throw StateError('No subscription is paused');
    paused.complete();
  }

  Future<void> get nextUnreadCatchUpStarted async {
    final started = _unreadCatchUpStarted;
    if (started == null) {
      throw StateError('No paused unread catch-up is pending');
    }
    await started.future;
  }

  void pauseNextUnreadCatchUp() {
    if (_pausedUnreadCatchUp != null) {
      throw StateError('An unread catch-up is already paused');
    }
    _pausedUnreadCatchUp = Completer<void>();
    _unreadCatchUpStarted = Completer<void>();
  }

  void resumePausedUnreadCatchUp() {
    final paused = _pausedUnreadCatchUp;
    if (paused == null) throw StateError('No unread catch-up is paused');
    paused.complete();
  }

  Future<void> get nextPausedQueryStarted async {
    final started = _pausedQueryStarted;
    if (started == null) throw StateError('No query is paused');
    await started.future;
  }

  void pauseQueryCall(int call) {
    _pausedQueryCall = call;
    _pausedQuery = Completer<void>();
    _pausedQueryStarted = Completer<void>();
  }

  void resumePausedQuery() {
    final paused = _pausedQuery;
    if (paused == null) throw StateError('No query is paused');
    paused.complete();
  }

  @override
  SessionState build() => const SessionState(status: SessionStatus.connected);

  @override
  Future<List<NostrEvent>> fetchHistory(
    NostrFilter filter, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    historyFilters.add(filter);
    if (filter.kinds.contains(39002) && filter.tags['#p'] != null) {
      if (membershipFailures > 0) {
        membershipFailures--;
        throw Exception('membership fetch failed');
      }
      // Membership query — return all memberships we have for this pubkey.
      final myPk = filter.tags['#p']?.single;
      return memberships
          .where(
            (e) =>
                e.tags.any((t) => t.length >= 2 && t[0] == 'p' && t[1] == myPk),
          )
          .toList();
    }
    if (filter.kinds.contains(EventKind.dmVisibility)) {
      return hiddenDmEvents;
    }
    if (filter.kinds.contains(39000)) {
      // Metadata query — return all metadata events whose `d` tag matches.
      final ids = (filter.tags['#d'] ?? const <String>[]).toSet();
      return metadata.where((e) => ids.contains(e.getTagValue('d'))).toList();
    }
    if (filter.since != null && filter.tags['#h']?.length == 1) {
      final paused = _pausedUnreadCatchUp;
      if (paused != null) {
        _unreadCatchUpStarted!.complete();
        await paused.future;
        _pausedUnreadCatchUp = null;
        _unreadCatchUpStarted = null;
      }
      final channelId = filter.tags['#h']!.single;
      return unreadEvents
          .where((event) => event.channelId == channelId)
          .toList();
    }
    return const [];
  }

  @override
  Future<List<NostrEvent>> queryRelay(
    List<NostrFilter> filters, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    queryBatches.add(List.of(filters));
    queryFilterBatches.add(List.of(filters));
    queryTimeouts.add(timeout);
    if (_pausedQueryCall == queryFilterBatches.length) {
      _pausedQueryStarted!.complete();
      await _pausedQuery!.future;
      _pausedQueryCall = null;
      _pausedQuery = null;
      _pausedQueryStarted = null;
    }
    if (queryFailureCalls.contains(queryFilterBatches.length)) {
      throw Exception('query failed');
    }
    if (filters.any((filter) => filter.since != null)) {
      final paused = _pausedUnreadCatchUp;
      if (paused != null) {
        _unreadCatchUpStarted!.complete();
        await paused.future;
        _pausedUnreadCatchUp = null;
        _unreadCatchUpStarted = null;
      }
    }
    final candidates = <NostrEvent>[
      ...recentMessages,
      ...queryEvents,
      ...unreadEvents,
    ];
    return candidates.where((event) {
      return filters.any((filter) {
        if (!filter.kinds.contains(event.kind)) return false;
        if (filter.since != null && event.createdAt < filter.since!) {
          return false;
        }
        for (final entry in filter.tags.entries) {
          final tagName = entry.key.startsWith('#')
              ? entry.key.substring(1)
              : entry.key;
          if (!event.tags.any(
            (tag) =>
                tag.length > 1 &&
                tag[0] == tagName &&
                entry.value.contains(tag[1]),
          )) {
            return false;
          }
        }
        return true;
      });
    }).toList();
  }

  @override
  Future<void Function()> subscribeWhenReady(
    NostrFilter filter,
    void Function(NostrEvent) onEvent, {
    void Function(String message)? onClosed,
    Future<void>? cancelled,
  }) =>
      _subscribeFake(filter, onEvent, onClosed: onClosed, cancelled: cancelled);

  @override
  Future<void Function()> subscribe(
    NostrFilter filter,
    void Function(NostrEvent) onEvent, {
    void Function(String message)? onClosed,
  }) => _subscribeFake(filter, onEvent, onClosed: onClosed);

  Future<void Function()> _subscribeFake(
    NostrFilter filter,
    void Function(NostrEvent) onEvent, {
    void Function(String message)? onClosed,
    Future<void>? cancelled,
  }) async {
    totalSubscribeCount++;
    subscribeFilters.add(filter);
    final channelId = filter.tags['#h']?.single;
    if (channelId != null && neverReadyChannelIds.contains(channelId)) {
      if (cancelled == null) return Completer<void Function()>().future;
      await cancelled;
      throw const RelaySubscriptionCancelledException();
    }
    final remainingFailures = channelId == null
        ? 0
        : subscribeFailuresByChannel[channelId] ?? 0;
    if (remainingFailures > 0) {
      subscribeFailuresByChannel[channelId!] = remainingFailures - 1;
      throw Exception('terminal subscription failure for $channelId');
    }
    final paused = _pausedSubscribe;
    if (paused != null && !_subscribeStarted!.isCompleted) {
      _subscribeStarted!.complete();
      if (cancelled == null) {
        await paused.future;
      } else {
        final wasCancelled = await Future.any([
          paused.future.then((_) => false),
          cancelled.then((_) => true),
        ]);
        if (wasCancelled) {
          subscribeFilters.remove(filter);
          throw const RelaySubscriptionCancelledException();
        }
      }
      _pausedSubscribe = null;
      _subscribeStarted = null;
    }
    final subscriptionKey = ++_nextSubscriptionKey;
    _subscriptions[subscriptionKey] = (filter, onEvent, onClosed);
    return () {
      final subscription = _subscriptions.remove(subscriptionKey);
      if (subscription == null) return;
      unsubscribeCount++;
      subscribeFilters.remove(subscription.$1);
    };
  }

  void setStatus(SessionStatus status) {
    state = SessionState(status: status);
  }

  void terminallyClose(String channelId) {
    final entry = _subscriptions.entries.singleWhere(
      (entry) => entry.value.$1.tags['#h']?.single == channelId,
    );
    _subscriptions.remove(entry.key);
    subscribeFilters.remove(entry.value.$1);
    entry.value.$3?.call('restricted: access revoked');
  }

  /// Emit a live event to all subscribers.
  void emit(NostrEvent event) {
    for (final (_, listener, _) in List.of(_subscriptions.values)) {
      listener(event);
    }
  }
}

class _TestTimer implements Timer {
  bool _isActive = true;

  @override
  bool get isActive => _isActive;

  @override
  int get tick => 0;

  @override
  void cancel() => _isActive = false;
}

class _FakeAppLifecycleNotifier extends AppLifecycleNotifier {
  @override
  AppLifecycleState build() => AppLifecycleState.resumed;
}
