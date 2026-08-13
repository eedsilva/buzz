import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:buzz/features/channels/channel_sections/channel_sections_manager.dart';
import 'package:buzz/features/channels/channel_sections/channel_sections_storage.dart';
import 'package:buzz/features/channels/channel_sections/section_workspace_sync.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nostr/nostr.dart' as nostr;
import 'package:shared_preferences/shared_preferences.dart';

class _WorkspaceHistoryRelaySession extends RelaySessionNotifier {
  _WorkspaceHistoryRelaySession(this.events);

  final List<NostrEvent> events;

  @override
  Future<List<NostrEvent>> fetchHistory(
    NostrFilter filter, {
    Duration timeout = const Duration(seconds: 8),
  }) async => events;
}

void main() {
  const owner =
      '1111111111111111111111111111111111111111111111111111111111111111';
  const sourceEvent =
      '2222222222222222222222222222222222222222222222222222222222222222';
  const sourceHash =
      '3333333333333333333333333333333333333333333333333333333333333333';
  const sectionA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const sectionB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  const channel = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

  Map<String, dynamic> projection({int revision = 4}) => {
    'version': 1,
    'owner_pubkey': owner,
    'revision': revision,
    'layout_revision': 1,
    'key_epoch': 2,
    'migration': {'source_event_id': sourceEvent, 'source_hash': sourceHash},
    'reader_key_envelope': 'nip44-envelope-reader-epoch-2',
    'sections': [
      {
        'id': sectionA,
        'rank': 0,
        'encrypted_label': 'ciphertext-alpha',
        'encrypted_icon': null,
      },
      {
        'id': sectionB,
        'rank': 1,
        'encrypted_label': 'ciphertext-beta',
        'encrypted_icon': 'ciphertext-icon',
      },
    ],
    'assignments': [
      {'channel_id': channel, 'section_id': sectionA, 'revision': 1},
    ],
  };

  test(
    'shared fixture projection cases and canonical command vectors remain exact',
    () {
      final fixture =
          jsonDecode(
                File('../docs/nips/NIP-SW.fixtures.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      final cases = fixture['projection_cases'] as List<dynamic>;
      for (final rawCase in cases) {
        final item = rawCase as Map<String, dynamic>;
        final incoming =
            (item['projection'] as Map<String, dynamic>)['revision'] as int;
        final previous = item['previous_revision'] as int?;
        final expected = switch (item['expect']) {
          'accept' => SectionWorkspaceRevisionAction.accept,
          'refetch' => SectionWorkspaceRevisionAction.refetch,
          'ignore' => SectionWorkspaceRevisionAction.ignore,
          _ => throw StateError('unknown fixture expectation'),
        };
        expect(sectionWorkspaceRevisionAction(previous, incoming), expected);
      }
      final canonicalization =
          fixture['canonicalization'] as Map<String, dynamic>;
      final legacy =
          canonicalization['legacy_plaintext'] as Map<String, dynamic>;
      final legacyCanonical = legacy['canonical'] as String;
      expect(sectionWorkspaceCanonicalJson(legacy['input']), legacyCanonical);
      expect(sectionWorkspaceSha256Hex(legacyCanonical), legacy['sha256']);
      final command =
          canonicalization['import_command'] as Map<String, dynamic>;
      final commandCanonical = command['canonical'] as String;
      expect(
        sectionWorkspaceCanonicalJson(jsonDecode(commandCanonical)),
        commandCanonical,
      );
      expect(sectionWorkspaceSha256Hex(commandCanonical), command['sha256']);
    },
  );

  test('strictly parses the complete shared projection case', () {
    final parsed = parseSectionWorkspaceProjection(projection());
    expect(parsed, isNotNull);
    expect(parsed!.sections.map((section) => section.id), [sectionA, sectionB]);
    expect(parsed.assignments.single.channelId, channel);
  });

  test(
    'parses the frozen revision-zero import and rejects unknown fields and versions',
    () {
      final fixture =
          jsonDecode(
                File('../docs/nips/NIP-SW.fixtures.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      final canonicalization =
          fixture['canonicalization'] as Map<String, dynamic>;
      final import = parseSectionWorkspaceImportJson(
        (canonicalization['import_command']
                as Map<String, dynamic>)['canonical']
            as String,
      );
      expect(import, isNotNull);
      expect(import!.actionId, 'dddddddd-dddd-4ddd-8ddd-dddddddddddd');
      expect(import.sections.single.id, sectionA);
      expect(import.assignments.single.sectionId, sectionA);

      final unknown = import.toJson()..['extra'] = true;
      expect(parseSectionWorkspaceImport(unknown), isNull);
      final wrongVersion = import.toJson()..['version'] = 2;
      expect(parseSectionWorkspaceImport(wrongVersion), isNull);
      final nestedUnknown = import.toJson();
      final firstSection = Map<String, dynamic>.from(
        ((nestedUnknown['sections'] as List).single as Map),
      )..['extra'] = true;
      nestedUnknown['sections'] = [firstSection];
      expect(parseSectionWorkspaceImport(nestedUnknown), isNull);
    },
  );

  test('canonical relay authority feeds the exact metadata AAD vector', () {
    expect(
      sectionWorkspaceAuthority(' wss://Relay.Example/// '),
      'relay.example',
    );
    expect(
      sectionWorkspaceAuthority('https://RELAY.EXAMPLE:443/'),
      'relay.example',
    );
    expect(
      sectionWorkspaceAuthority('wss://Relay.Example:8443/'),
      'relay.example:8443',
    );

    final crypto = SectionWorkspaceMetadataCrypto(
      Uint8List.fromList(List<int>.generate(32, (index) => index)),
    );
    final envelope = crypto.encrypt(
      plaintext: 'Alpha',
      community: sectionWorkspaceAuthority('wss://Relay.Example/'),
      ownerPubkey: owner,
      sectionId: sectionA,
      keyEpoch: 1,
      purpose: 'label',
      nonce: Uint8List.fromList(List<int>.generate(12, (index) => index)),
    );
    expect(envelope, 'aes256gcm:AAECAwQFBgcICQoL:Bm6mc6SHvhxcEB6Q1Lc56VuJZjD7');
  });

  test(
    'rejects unknown fields and unsupported versions at every typed level',
    () {
      final unknown = projection()..['extra'] = true;
      expect(parseSectionWorkspaceProjection(unknown), isNull);

      final nestedUnknown = projection();
      final nestedMigration = Map<String, dynamic>.from(
        nestedUnknown['migration'] as Map,
      );
      nestedMigration['extra'] = true;
      nestedUnknown['migration'] = nestedMigration;
      expect(parseSectionWorkspaceProjection(nestedUnknown), isNull);

      final sectionUnknown = projection();
      final firstSection = Map<String, dynamic>.from(
        ((sectionUnknown['sections'] as List).first as Map),
      );
      firstSection['extra'] = true;
      sectionUnknown['sections'] = [
        firstSection,
        ...(sectionUnknown['sections'] as List).skip(1),
      ];
      expect(parseSectionWorkspaceProjection(sectionUnknown), isNull);

      final assignmentUnknown = projection();
      final firstAssignment = Map<String, dynamic>.from(
        ((assignmentUnknown['assignments'] as List).first as Map),
      );
      firstAssignment['extra'] = true;
      assignmentUnknown['assignments'] = [
        firstAssignment,
        ...(assignmentUnknown['assignments'] as List).skip(1),
      ];
      expect(parseSectionWorkspaceProjection(assignmentUnknown), isNull);

      final wrongVersion = projection()..['version'] = 2;
      expect(parseSectionWorkspaceProjection(wrongVersion), isNull);
    },
  );

  test('rejects malformed shape, duplicate ids, and non-permutation ranks', () {
    final duplicateId = projection();
    (duplicateId['sections'] as List)[1]['id'] = sectionA;
    expect(parseSectionWorkspaceProjection(duplicateId), isNull);

    final badRank = projection();
    (badRank['sections'] as List)[1]['rank'] = 0;
    expect(parseSectionWorkspaceProjection(badRank), isNull);

    final unknownSection = projection();
    (unknownSection['assignments'] as List).single['section_id'] = sectionB;
    expect(parseSectionWorkspaceProjection(unknownSection), isNotNull);
    (unknownSection['assignments'] as List).single['section_id'] =
        'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
    expect(parseSectionWorkspaceProjection(unknownSection), isNull);
  });

  test('duplicate JSON keys and fractional numbers fail strict decoding', () {
    final valid = jsonEncode(projection());
    expect(parseSectionWorkspaceProjectionJson(valid), isNotNull);
    expect(
      parseSectionWorkspaceProjectionJson(
        valid.replaceFirst('{"version":1', '{"version":1,"version":1'),
      ),
      isNull,
    );
    expect(
      parseSectionWorkspaceProjectionJson(
        valid.replaceFirst('"revision":4', '"revision":4.5'),
      ),
      isNull,
    );
  });

  test(
    'revision behavior matches accept, refetch, and ignore fixture cases',
    () {
      expect(
        sectionWorkspaceRevisionAction(null, 4),
        SectionWorkspaceRevisionAction.accept,
      );
      expect(
        sectionWorkspaceRevisionAction(4, 6),
        SectionWorkspaceRevisionAction.refetch,
      );
      expect(
        sectionWorkspaceRevisionAction(4, 3),
        SectionWorkspaceRevisionAction.ignore,
      );
      expect(
        sectionWorkspaceRevisionAction(4, 4),
        SectionWorkspaceRevisionAction.ignore,
      );
    },
  );

  test('legacy parser rejects unknown, version, and malformed documents', () {
    final valid = {
      'version': 1,
      'sections': [
        {'id': sectionA, 'name': 'Alpha', 'icon': null, 'order': 0},
      ],
      'assignments': {channel: sectionA},
    };
    expect(parseSectionWorkspaceLegacy(valid), isNotNull);

    expect(parseSectionWorkspaceLegacy({...valid, 'extra': true}), isNull);
    expect(parseSectionWorkspaceLegacy({...valid, 'version': 2}), isNull);
    expect(
      parseSectionWorkspaceLegacy({
        ...valid,
        'sections': [
          {'id': sectionA, 'name': 'Alpha', 'icon': null, 'order': 1},
        ],
      }),
      isNull,
    );
    expect(
      parseSectionWorkspaceLegacy({
        ...valid,
        'assignments': {channel: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'},
      }),
      isNull,
    );
  });

  test('canonicalization matches the shared legacy plaintext vector', () {
    final input = {
      'version': 1,
      'sections': [
        {'id': sectionA, 'name': 'Alpha', 'icon': 'folder', 'order': 0},
      ],
      'assignments': {channel: sectionA},
    };
    const expected =
        '{"assignments":{"cccccccc-cccc-4ccc-8ccc-cccccccccccc":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"},"sections":[{"icon":"folder","id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","name":"Alpha","order":0}],"version":1}';
    expect(sectionWorkspaceCanonicalJson(input), expected);
    expect(
      sectionWorkspaceSha256Hex(expected),
      '336ba846d8a2aef9ca7de80e494201e503b64fa364ec1a629873f3fa83232d5d',
    );
  });

  test('AES-GCM metadata vector authenticates its complete AAD', () {
    final crypto = SectionWorkspaceMetadataCrypto(
      Uint8List.fromList(List<int>.generate(32, (index) => index)),
    );
    const kwargs = {
      'community': 'relay.example',
      'ownerPubkey': owner,
      'sectionId': sectionA,
      'keyEpoch': 1,
    };
    final envelope = crypto.encrypt(
      plaintext: 'Alpha',
      community: kwargs['community']! as String,
      ownerPubkey: kwargs['ownerPubkey']! as String,
      sectionId: kwargs['sectionId']! as String,
      keyEpoch: kwargs['keyEpoch']! as int,
      purpose: 'label',
      nonce: Uint8List.fromList(List<int>.generate(12, (index) => index)),
    );
    expect(envelope, 'aes256gcm:AAECAwQFBgcICQoL:Bm6mc6SHvhxcEB6Q1Lc56VuJZjD7');
    expect(
      crypto.decrypt(
        envelope: envelope,
        community: kwargs['community']! as String,
        ownerPubkey: kwargs['ownerPubkey']! as String,
        sectionId: kwargs['sectionId']! as String,
        keyEpoch: kwargs['keyEpoch']! as int,
        purpose: 'label',
      ),
      'Alpha',
    );
    expect(
      () => crypto.decrypt(
        envelope: envelope,
        community: kwargs['community']! as String,
        ownerPubkey: kwargs['ownerPubkey']! as String,
        sectionId: kwargs['sectionId']! as String,
        keyEpoch: 2,
        purpose: 'label',
      ),
      throwsA(anything),
    );
  });

  test(
    'cache write failure leaves staged projection and legacy state untouched',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final ownerKeys = nostr.Keys.generate();
      final relayKeys = nostr.Keys.generate();
      final sectionId = sectionA;
      final oldStore = {
        'version': 1,
        'sections': [
          {'id': sectionId, 'name': 'Legacy', 'order': 0},
        ],
        'assignments': <String, String>{},
      };
      await prefs.setString(
        channelSectionsKey(ownerKeys.public),
        jsonEncode(oldStore),
      );
      final workspaceKey = Uint8List.fromList(
        List<int>.generate(32, (index) => index),
      );
      final envelope = SectionWorkspaceKeyEnvelopeCrypto(
        nsec: ownerKeys.nsec,
        ownerPubkey: ownerKeys.public,
      ).wrap(workspaceKey);
      final metadata = SectionWorkspaceMetadataCrypto(workspaceKey);
      final projectionValue = {
        'version': 1,
        'owner_pubkey': ownerKeys.public,
        'revision': 1,
        'layout_revision': 1,
        'key_epoch': 1,
        'migration': {
          'source_event_id': sourceEvent,
          'source_hash': sourceHash,
        },
        'reader_key_envelope': envelope,
        'sections': [
          {
            'id': sectionId,
            'rank': 0,
            'encrypted_label': metadata.encrypt(
              plaintext: 'Projected',
              community: 'relay.example',
              ownerPubkey: ownerKeys.public,
              sectionId: sectionId,
              keyEpoch: 1,
              purpose: 'label',
            ),
            'encrypted_icon': null,
          },
        ],
        'assignments': [],
      };
      final relayEvent = nostr.Event.from(
        kind: sectionWorkspaceProjectionKind,
        content: jsonEncode(projectionValue),
        tags: [
          ['d', ownerKeys.public],
          ['p', ownerKeys.public],
        ],
        secretKey: relayKeys.secret,
        createdAt: 1700000000,
      );
      final relaySession = _WorkspaceHistoryRelaySession([
        NostrEvent.fromJson(relayEvent.toMap()),
      ]);
      var renders = 0;
      late final ChannelSectionsManager manager;
      final sync = SectionWorkspaceSyncManager(
        ownerPubkey: ownerKeys.public,
        nsec: ownerKeys.nsec,
        prefs: prefs,
        relaySession: relaySession,
        signedEventRelay: null,
        relaySelfProvider: () async => relayKeys.public,
        relayAuthority: 'wss://relay.example',
        stageProjection: (projection) =>
            manager.stageWorkspaceProjection(projection),
        commitProjection: (staged) {
          renders++;
          return manager.commitWorkspaceProjection(staged);
        },
        cacheWriter: (_, _, _, _) async => false,
      );
      manager = ChannelSectionsManager(
        pubkey: ownerKeys.public,
        prefs: prefs,
        crypto: ChannelSectionsCrypto(ownerKeys.nsec, ownerKeys.public),
        relaySession: null,
        signedEventRelay: null,
        remoteEnabled: false,
        workspaceSync: sync,
        onChanged: () => renders++,
      );

      expect(await sync.probe(), isFalse);
      expect(manager.store.sections.single.name, 'Legacy');
      expect(renders, 0);
      expect(sync.cache, isNull);
      expect(
        prefs.getString(
          channelSectionsKey(
            ownerKeys.public,
            relayAuthority: sync.relayStorageScope,
          ),
        ),
        jsonEncode(oldStore),
      );
      manager.dispose(flushPending: false);
    },
  );

  test('cache persists the last verified projection and key epoch', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final parsed = parseSectionWorkspaceProjection(projection())!;
    final cache = SectionWorkspaceCache(
      eventId: sourceEvent,
      projection: parsed,
    );
    await writeSectionWorkspaceCache(prefs, owner, 'relay.example', cache);
    final restored = readSectionWorkspaceCache(prefs, owner, 'relay.example');
    expect(restored!.eventId, sourceEvent);
    expect(restored.projection.revision, 4);
    expect(restored.projection.keyEpoch, 2);
    expect(restored.toJson()['revision'], 4);
    expect(restored.toJson()['key_epoch'], 2);
  });
}
