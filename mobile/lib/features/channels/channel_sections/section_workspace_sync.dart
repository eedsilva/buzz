import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:nostr/nostr.dart' as nostr;
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/gcm.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../../shared/crypto/ecdh.dart';
import '../../../shared/crypto/nip44.dart';
import '../../../shared/relay/relay.dart';
import 'channel_sections_storage.dart';

const sectionWorkspaceVersion = 1;
const sectionWorkspaceImportKind = 9050;
const sectionWorkspaceProjectionKind = 30623;
const sectionWorkspaceMaxSections = 100;
const sectionWorkspaceMaxAssignments = 1000;
const sectionWorkspaceMaxGrants = 256;
const sectionWorkspaceMaxEncryptedMetadataBytes = 65535;
const sectionWorkspaceMaxKeyEnvelopeBytes = 4096;

final _sectionWorkspaceUuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
final _sectionWorkspaceHex64 = RegExp(r'^[0-9a-f]{64}$');
bool verifySectionWorkspaceNostrEvent(NostrEvent event) {
  try {
    final verifiedEvent = nostr.Event.fromJson(jsonEncode(event.toJson()));
    return verifiedEvent.id == event.id &&
        verifiedEvent.pubkey == event.pubkey &&
        verifiedEvent.createdAt == event.createdAt &&
        verifiedEvent.kind == event.kind &&
        verifiedEvent.tags.length == event.tags.length &&
        _sameSectionWorkspaceTags(verifiedEvent.tags, event.tags) &&
        verifiedEvent.content == event.content &&
        verifiedEvent.sig == event.sig;
  } catch (_) {
    return false;
  }
}

bool _sameSectionWorkspaceTags(
  List<List<String>> left,
  List<List<String>> right,
) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index].length != right[index].length) return false;
    for (var tagIndex = 0; tagIndex < left[index].length; tagIndex++) {
      if (left[index][tagIndex] != right[index][tagIndex]) return false;
    }
  }
  return true;
}

bool _validSectionWorkspaceUuid(Object? value) =>
    value is String &&
    value != '00000000-0000-0000-0000-000000000000' &&
    _sectionWorkspaceUuid.hasMatch(value);

class SectionWorkspaceProjection {
  final int version;
  final String ownerPubkey;
  final int revision;
  final int layoutRevision;
  final int keyEpoch;
  final String sourceEventId;
  final String sourceHash;
  final String readerKeyEnvelope;
  final List<SectionWorkspaceProjectedSection> sections;
  final List<SectionWorkspaceProjectedAssignment> assignments;

  const SectionWorkspaceProjection({
    required this.version,
    required this.ownerPubkey,
    required this.revision,
    required this.layoutRevision,
    required this.keyEpoch,
    required this.sourceEventId,
    required this.sourceHash,
    required this.readerKeyEnvelope,
    required this.sections,
    required this.assignments,
  });

  Map<String, dynamic> toJson() => {
    'version': version,
    'owner_pubkey': ownerPubkey,
    'revision': revision,
    'layout_revision': layoutRevision,
    'key_epoch': keyEpoch,
    'migration': {'source_event_id': sourceEventId, 'source_hash': sourceHash},
    'reader_key_envelope': readerKeyEnvelope,
    'sections': sections.map((section) => section.toJson()).toList(),
    'assignments': assignments
        .map((assignment) => assignment.toJson())
        .toList(),
  };
}

class SectionWorkspaceProjectedSection {
  final String id;
  final int rank;
  final String encryptedLabel;
  final String? encryptedIcon;

  const SectionWorkspaceProjectedSection({
    required this.id,
    required this.rank,
    required this.encryptedLabel,
    required this.encryptedIcon,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'rank': rank,
    'encrypted_label': encryptedLabel,
    'encrypted_icon': encryptedIcon,
  };
}

class SectionWorkspaceProjectedAssignment {
  final String channelId;
  final String sectionId;
  final int revision;

  const SectionWorkspaceProjectedAssignment({
    required this.channelId,
    required this.sectionId,
    required this.revision,
  });

  Map<String, dynamic> toJson() => {
    'channel_id': channelId,
    'section_id': sectionId,
    'revision': revision,
  };
}

class SectionWorkspaceImport {
  final int version;
  final String actionId;
  final String sourceEventId;
  final String sourceHash;
  final int keyEpoch;
  final String ownerKeyEnvelope;
  final List<SectionWorkspaceProjectedSection> sections;
  final List<SectionWorkspaceImportAssignment> assignments;

  const SectionWorkspaceImport({
    required this.version,
    required this.actionId,
    required this.sourceEventId,
    required this.sourceHash,
    required this.keyEpoch,
    required this.ownerKeyEnvelope,
    required this.sections,
    required this.assignments,
  });

  Map<String, dynamic> toJson() => {
    'version': version,
    'action_id': actionId,
    'source_event_id': sourceEventId,
    'source_hash': sourceHash,
    'key_epoch': keyEpoch,
    'owner_key_envelope': ownerKeyEnvelope,
    'sections': sections.map((section) => section.toJson()).toList(),
    'assignments': assignments
        .map((assignment) => assignment.toJson())
        .toList(),
  };
}

class SectionWorkspaceImportAssignment {
  final String channelId;
  final String sectionId;

  const SectionWorkspaceImportAssignment({
    required this.channelId,
    required this.sectionId,
  });

  Map<String, dynamic> toJson() => {
    'channel_id': channelId,
    'section_id': sectionId,
  };
}

SectionWorkspaceImport? parseSectionWorkspaceImport(Object? value) {
  if (value is! Map<String, dynamic> ||
      !_exactKeys(value, const [
        'version',
        'action_id',
        'source_event_id',
        'source_hash',
        'key_epoch',
        'owner_key_envelope',
        'sections',
        'assignments',
      ])) {
    return null;
  }
  final version = value['version'];
  final actionId = value['action_id'];
  final sourceEventId = value['source_event_id'];
  final sourceHash = value['source_hash'];
  final keyEpoch = value['key_epoch'];
  final ownerEnvelope = value['owner_key_envelope'];
  final rawSections = value['sections'];
  final rawAssignments = value['assignments'];
  if (version is! int ||
      version != sectionWorkspaceVersion ||
      actionId is! String ||
      !_validSectionWorkspaceUuid(actionId) ||
      sourceEventId is! String ||
      !_sectionWorkspaceHex64.hasMatch(sourceEventId) ||
      sourceHash is! String ||
      !_sectionWorkspaceHex64.hasMatch(sourceHash) ||
      keyEpoch != 1 ||
      ownerEnvelope is! String ||
      !_validCiphertext(ownerEnvelope, sectionWorkspaceMaxKeyEnvelopeBytes) ||
      rawSections is! List ||
      rawSections.length > sectionWorkspaceMaxSections ||
      rawAssignments is! List ||
      rawAssignments.length > sectionWorkspaceMaxAssignments) {
    return null;
  }
  final ids = <String>{};
  final ranks = <int>{};
  final sections = <SectionWorkspaceProjectedSection>[];
  for (final raw in rawSections) {
    if (raw is! Map<String, dynamic> ||
        !_exactKeys(raw, const [
          'id',
          'rank',
          'encrypted_label',
          'encrypted_icon',
        ])) {
      return null;
    }
    final id = raw['id'];
    final rank = raw['rank'];
    final label = raw['encrypted_label'];
    final icon = raw['encrypted_icon'];
    if (id is! String ||
        !_validSectionWorkspaceUuid(id) ||
        !ids.add(id) ||
        rank is! int ||
        rank < 0 ||
        rank >= rawSections.length ||
        !ranks.add(rank) ||
        label is! String ||
        !_validCiphertext(label, sectionWorkspaceMaxEncryptedMetadataBytes) ||
        (icon != null &&
            (icon is! String ||
                !_validCiphertext(
                  icon,
                  sectionWorkspaceMaxEncryptedMetadataBytes,
                )))) {
      return null;
    }
    sections.add(
      SectionWorkspaceProjectedSection(
        id: id,
        rank: rank,
        encryptedLabel: label,
        encryptedIcon: icon as String?,
      ),
    );
  }
  if (!List.generate(sections.length, (index) => index).every(ranks.contains)) {
    return null;
  }
  final channels = <String>{};
  final assignments = <SectionWorkspaceImportAssignment>[];
  for (final raw in rawAssignments) {
    if (raw is! Map<String, dynamic> ||
        !_exactKeys(raw, const ['channel_id', 'section_id'])) {
      return null;
    }
    final channelId = raw['channel_id'];
    final sectionId = raw['section_id'];
    if (channelId is! String ||
        !_validSectionWorkspaceUuid(channelId) ||
        !channels.add(channelId) ||
        sectionId is! String ||
        !_validSectionWorkspaceUuid(sectionId) ||
        !ids.contains(sectionId)) {
      return null;
    }
    assignments.add(
      SectionWorkspaceImportAssignment(
        channelId: channelId,
        sectionId: sectionId,
      ),
    );
  }
  return SectionWorkspaceImport(
    version: version,
    actionId: actionId,
    sourceEventId: sourceEventId,
    sourceHash: sourceHash,
    keyEpoch: keyEpoch,
    ownerKeyEnvelope: ownerEnvelope,
    sections: sections,
    assignments: assignments,
  );
}

SectionWorkspaceImport? parseSectionWorkspaceImportJson(String json) {
  final value = parseSectionWorkspaceJson(json);
  return parseSectionWorkspaceImport(value);
}

/// Decode a NIP-SW JSON document without accepting duplicate object keys or
/// fractional numbers. This is also used for legacy plaintext before its
/// source hash is computed, so the hash covers the exact decoded document.
Object? parseSectionWorkspaceJson(String json) {
  try {
    if (_hasDuplicateJsonObjectKeys(json)) return null;
    final value = jsonDecode(json);
    if (!_allJsonNumbersAreIntegers(value)) return null;
    return value;
  } catch (_) {
    return null;
  }
}

class SectionWorkspaceCache {
  final String eventId;
  final SectionWorkspaceProjection projection;

  const SectionWorkspaceCache({
    required this.eventId,
    required this.projection,
  });

  Map<String, dynamic> toJson() => {
    'event_id': eventId,
    'revision': projection.revision,
    'key_epoch': projection.keyEpoch,
    'projection': projection.toJson(),
  };
}

enum SectionWorkspaceRevisionAction { accept, refetch, ignore }

SectionWorkspaceRevisionAction sectionWorkspaceRevisionAction(
  int? previousRevision,
  int incomingRevision,
) {
  if (previousRevision == null) return SectionWorkspaceRevisionAction.accept;
  if (incomingRevision <= previousRevision) {
    return SectionWorkspaceRevisionAction.ignore;
  }
  if (incomingRevision == previousRevision + 1) {
    return SectionWorkspaceRevisionAction.accept;
  }
  return SectionWorkspaceRevisionAction.refetch;
}

/// Strictly parses the NIP-SW projection shape. All object keys are checked,
/// including nested migration, section, and assignment objects.
SectionWorkspaceProjection? parseSectionWorkspaceProjection(Object? value) {
  if (value is! Map<String, dynamic>) return null;
  if (!_exactKeys(value, const [
    'version',
    'owner_pubkey',
    'revision',
    'layout_revision',
    'key_epoch',
    'migration',
    'reader_key_envelope',
    'sections',
    'assignments',
  ])) {
    return null;
  }
  final migration = value['migration'];
  if (migration is! Map<String, dynamic> ||
      !_exactKeys(migration, const ['source_event_id', 'source_hash'])) {
    return null;
  }
  final version = value['version'];
  final owner = value['owner_pubkey'];
  final revision = value['revision'];
  final layoutRevision = value['layout_revision'];
  final keyEpoch = value['key_epoch'];
  final readerEnvelope = value['reader_key_envelope'];
  if (version is! int ||
      version != sectionWorkspaceVersion ||
      owner is! String ||
      !_sectionWorkspaceHex64.hasMatch(owner) ||
      revision is! int ||
      revision < 0 ||
      layoutRevision is! int ||
      layoutRevision < 0 ||
      keyEpoch is! int ||
      keyEpoch < 1 ||
      readerEnvelope is! String ||
      !_validCiphertext(readerEnvelope, sectionWorkspaceMaxKeyEnvelopeBytes) ||
      migration['source_event_id'] is! String ||
      migration['source_hash'] is! String ||
      !_sectionWorkspaceHex64.hasMatch(
        migration['source_event_id'] as String,
      ) ||
      !_sectionWorkspaceHex64.hasMatch(migration['source_hash'] as String)) {
    return null;
  }

  final rawSections = value['sections'];
  if (rawSections is! List ||
      rawSections.length > sectionWorkspaceMaxSections) {
    return null;
  }
  final sectionIds = <String>{};
  final sections = <SectionWorkspaceProjectedSection>[];
  for (final raw in rawSections) {
    if (raw is! Map<String, dynamic> ||
        !_exactKeys(raw, const [
          'id',
          'rank',
          'encrypted_label',
          'encrypted_icon',
        ])) {
      return null;
    }
    final id = raw['id'];
    final rank = raw['rank'];
    final label = raw['encrypted_label'];
    final icon = raw['encrypted_icon'];
    if (id is! String ||
        !_validSectionWorkspaceUuid(id) ||
        !sectionIds.add(id) ||
        rank is! int ||
        rank < 0 ||
        rank >= rawSections.length ||
        label is! String ||
        !_validCiphertext(label, sectionWorkspaceMaxEncryptedMetadataBytes) ||
        (icon != null &&
            (icon is! String ||
                !_validCiphertext(
                  icon,
                  sectionWorkspaceMaxEncryptedMetadataBytes,
                )))) {
      return null;
    }
    sections.add(
      SectionWorkspaceProjectedSection(
        id: id,
        rank: rank,
        encryptedLabel: label,
        encryptedIcon: icon as String?,
      ),
    );
  }
  final ranks = sections.map((section) => section.rank).toSet();
  if (ranks.length != sections.length ||
      !List.generate(sections.length, (index) => index).every(ranks.contains)) {
    return null;
  }

  final rawAssignments = value['assignments'];
  if (rawAssignments is! List ||
      rawAssignments.length > sectionWorkspaceMaxAssignments) {
    return null;
  }
  final channelIds = <String>{};
  final assignments = <SectionWorkspaceProjectedAssignment>[];
  for (final raw in rawAssignments) {
    if (raw is! Map<String, dynamic> ||
        !_exactKeys(raw, const ['channel_id', 'section_id', 'revision'])) {
      return null;
    }
    final channelId = raw['channel_id'];
    final sectionId = raw['section_id'];
    final assignmentRevision = raw['revision'];
    if (channelId is! String ||
        !_validSectionWorkspaceUuid(channelId) ||
        !channelIds.add(channelId) ||
        sectionId is! String ||
        !_validSectionWorkspaceUuid(sectionId) ||
        !sectionIds.contains(sectionId) ||
        assignmentRevision is! int ||
        assignmentRevision < 0) {
      return null;
    }
    assignments.add(
      SectionWorkspaceProjectedAssignment(
        channelId: channelId,
        sectionId: sectionId,
        revision: assignmentRevision,
      ),
    );
  }

  return SectionWorkspaceProjection(
    version: version,
    ownerPubkey: owner,
    revision: revision,
    layoutRevision: layoutRevision,
    keyEpoch: keyEpoch,
    sourceEventId: migration['source_event_id'] as String,
    sourceHash: migration['source_hash'] as String,
    readerKeyEnvelope: readerEnvelope,
    sections: sections,
    assignments: assignments,
  );
}

SectionWorkspaceProjection? parseSectionWorkspaceProjectionJson(String json) {
  try {
    if (_hasDuplicateJsonObjectKeys(json)) return null;
    final value = jsonDecode(json);
    if (!_allJsonNumbersAreIntegers(value)) return null;
    return parseSectionWorkspaceProjection(value);
  } catch (_) {
    return null;
  }
}

class SectionWorkspaceLegacyParseResult {
  final Map<String, dynamic> value;
  final ChannelSectionStore store;

  const SectionWorkspaceLegacyParseResult({
    required this.value,
    required this.store,
  });
}

SectionWorkspaceLegacyParseResult? parseSectionWorkspaceLegacy(Object? value) {
  if (value is! Map<String, dynamic> ||
      !_exactKeys(value, const ['version', 'sections', 'assignments'])) {
    return null;
  }
  final version = value['version'];
  final rawSections = value['sections'];
  final rawAssignments = value['assignments'];
  if (version is! int ||
      version != 1 ||
      rawSections is! List ||
      rawSections.length > sectionWorkspaceMaxSections ||
      rawAssignments is! Map<String, dynamic> ||
      rawAssignments.length > sectionWorkspaceMaxAssignments) {
    return null;
  }

  final ids = <String>{};
  final orders = <int>{};
  final sections = <ChannelSection>[];
  for (final raw in rawSections) {
    if (raw is! Map<String, dynamic> ||
        raw.keys.any(
          (key) => !const {'id', 'name', 'icon', 'order'}.contains(key),
        ) ||
        raw.length < 3) {
      return null;
    }
    final id = raw['id'];
    final name = raw['name'];
    final icon = raw['icon'];
    final order = raw['order'];
    if (id is! String ||
        !_validSectionWorkspaceUuid(id) ||
        !ids.add(id) ||
        name is! String ||
        name.isEmpty ||
        utf8.encode(name).length > sectionWorkspaceMaxEncryptedMetadataBytes ||
        (icon != null && icon is! String) ||
        (icon is String &&
            utf8.encode(icon).length >
                sectionWorkspaceMaxEncryptedMetadataBytes) ||
        order is! int ||
        order < 0 ||
        order >= rawSections.length ||
        !orders.add(order)) {
      return null;
    }
    sections.add(
      ChannelSection(id: id, name: name, icon: icon as String?, order: order),
    );
  }
  if (!List.generate(
    sections.length,
    (index) => index,
  ).every(orders.contains)) {
    return null;
  }

  final assignments = <String, String>{};
  for (final entry in rawAssignments.entries) {
    final channelId = entry.key;
    final sectionId = entry.value;
    if (!_validSectionWorkspaceUuid(channelId) ||
        sectionId is! String ||
        !_validSectionWorkspaceUuid(sectionId) ||
        !ids.contains(sectionId)) {
      return null;
    }
    assignments[channelId] = sectionId;
  }
  return SectionWorkspaceLegacyParseResult(
    value: value,
    store: ChannelSectionStore(sections: sections, assignments: assignments),
  );
}

SectionWorkspaceLegacyParseResult? parseSectionWorkspaceLegacyJson(
  String json,
) {
  final value = parseSectionWorkspaceJson(json);
  return parseSectionWorkspaceLegacy(value);
}

String sectionWorkspaceCanonicalJson(Object? value) {
  final out = StringBuffer();
  void write(Object? current) {
    if (current == null || current is bool || current is String) {
      out.write(jsonEncode(current));
      return;
    }
    if (current is int) {
      out.write(current);
      return;
    }
    if (current is num) {
      throw const FormatException(
        'NIP-SW canonical JSON permits integers only',
      );
    }
    if (current is List) {
      out.write('[');
      for (var index = 0; index < current.length; index++) {
        if (index != 0) out.write(',');
        write(current[index]);
      }
      out.write(']');
      return;
    }
    if (current is Map) {
      final keys = current.keys.whereType<String>().toList()
        ..sort(_compareUnicodeCodePoints);
      if (keys.length != current.length) {
        throw const FormatException(
          'NIP-SW canonical JSON keys must be strings',
        );
      }
      out.write('{');
      for (var index = 0; index < keys.length; index++) {
        if (index != 0) out.write(',');
        final key = keys[index];
        write(key);
        out.write(':');
        write(current[key]);
      }
      out.write('}');
      return;
    }
    throw const FormatException('unsupported JSON value');
  }

  write(value);
  return out.toString();
}

String sectionWorkspaceSha256Hex(String canonical) => bytesToHex(
  SHA256Digest().process(Uint8List.fromList(utf8.encode(canonical))),
);

String sectionWorkspaceStorageScope(String relayUrl) =>
    relayUrl.trim().replaceAll(RegExp(r'/+$'), '').toLowerCase();

String sectionWorkspaceCacheKey(String ownerPubkey, String relayUrl) =>
    'buzz.section-workspace.v1:$ownerPubkey:${Uri.encodeComponent(sectionWorkspaceStorageScope(relayUrl))}';

SectionWorkspaceCache? readSectionWorkspaceCache(
  SharedPreferences prefs,
  String ownerPubkey,
  String relayUrl,
) {
  final raw = prefs.getString(sectionWorkspaceCacheKey(ownerPubkey, relayUrl));
  if (raw == null || raw.isEmpty) return null;
  try {
    final value = parseSectionWorkspaceJson(raw);
    if (value is! Map<String, dynamic> ||
        !_exactKeys(value, const [
          'event_id',
          'revision',
          'key_epoch',
          'projection',
        ]) ||
        value['event_id'] is! String ||
        !_sectionWorkspaceHex64.hasMatch(value['event_id'] as String) ||
        value['revision'] is! int ||
        value['key_epoch'] is! int ||
        value['projection'] is! Map<String, dynamic>) {
      return null;
    }
    final projection = parseSectionWorkspaceProjection(value['projection']);
    if (projection == null ||
        projection.ownerPubkey != ownerPubkey ||
        value['revision'] != projection.revision ||
        value['key_epoch'] != projection.keyEpoch) {
      return null;
    }
    return SectionWorkspaceCache(
      eventId: value['event_id'] as String,
      projection: projection,
    );
  } catch (_) {
    return null;
  }
}

Future<bool> writeSectionWorkspaceCache(
  SharedPreferences prefs,
  String ownerPubkey,
  String relayUrl,
  SectionWorkspaceCache cache,
) => prefs.setString(
  sectionWorkspaceCacheKey(ownerPubkey, relayUrl),
  jsonEncode(cache.toJson()),
);

/// Normalize the relay authority used by NIP-SW metadata AAD. This mirrors
/// the desktop lane's host/port authority normalization rather than the full
/// WebSocket URL: scheme, path, query, and fragment are not part of AAD.
String sectionWorkspaceAuthority(String relayUrl) {
  final trimmed = relayUrl.trim();
  final parsed = Uri.tryParse(trimmed);
  if (parsed != null &&
      parsed.host.isNotEmpty &&
      const {'ws', 'wss', 'http', 'https'}.contains(parsed.scheme)) {
    final hostValue = parsed.host.toLowerCase();
    final host = hostValue.endsWith('.')
        ? hostValue.substring(0, hostValue.length - 1)
        : hostValue;
    final authorityHost = host.contains(':') ? '[$host]' : host;
    final defaultPort = switch (parsed.scheme) {
      'http' || 'ws' => 80,
      'https' || 'wss' => 443,
      _ => 0,
    };
    // URL authority canonicalization omits an explicit default port, matching
    // the browser/desktop URL implementation, but retains non-default ports.
    return parsed.port == 0 || parsed.port == defaultPort
        ? authorityHost
        : '$authorityHost:${parsed.port}';
  }
  return trimmed.replaceAll(RegExp(r'/+$'), '').toLowerCase();
}

Future<String?> fetchSectionWorkspaceRelaySelf(String relayUrl) async {
  final client = http.Client();
  try {
    final parsed = Uri.tryParse(relayUrl.trim());
    if (parsed == null || parsed.host.isEmpty) return null;
    final scheme = switch (parsed.scheme) {
      'wss' => 'https',
      'ws' => 'http',
      'https' || 'http' => parsed.scheme,
      _ => null,
    };
    if (scheme == null) return null;
    final uri = parsed.replace(scheme: scheme);
    final response = await client
        .get(uri, headers: const {'Accept': 'application/nostr+json'})
        .timeout(const Duration(seconds: 5));
    if (response.statusCode < 200 || response.statusCode >= 300) return null;
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) return null;
    final self = decoded['self'];
    if (self is! String || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(self)) {
      return null;
    }
    return self.toLowerCase();
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
}

class SectionWorkspaceMetadataCrypto {
  final Uint8List key;

  SectionWorkspaceMetadataCrypto(this.key) {
    if (key.length != 32) throw ArgumentError('workspace key must be 32 bytes');
  }

  String encrypt({
    required String plaintext,
    required String community,
    required String ownerPubkey,
    required String sectionId,
    required int keyEpoch,
    required String purpose,
    Uint8List? nonce,
  }) {
    if (purpose != 'label' && purpose != 'icon') {
      throw ArgumentError('invalid metadata purpose');
    }
    final actualNonce = nonce ?? secureRandomBytes(12);
    if (actualNonce.length != 12) {
      throw ArgumentError('AES-GCM nonce must be 12 bytes');
    }
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(
          KeyParameter(key),
          128,
          actualNonce,
          Uint8List.fromList(
            utf8.encode(
              sectionWorkspaceCanonicalJson({
                'version': 1,
                'community': community,
                'owner_pubkey': ownerPubkey,
                'section_id': sectionId,
                'key_epoch': keyEpoch,
                'purpose': purpose,
              }),
            ),
          ),
        ),
      );
    final ciphertext = cipher.process(
      Uint8List.fromList(utf8.encode(plaintext)),
    );
    return 'aes256gcm:${_base64UrlNoPad(actualNonce)}:${_base64UrlNoPad(ciphertext)}';
  }

  String decrypt({
    required String envelope,
    required String community,
    required String ownerPubkey,
    required String sectionId,
    required int keyEpoch,
    required String purpose,
  }) {
    final parts = envelope.split(':');
    if (parts.length != 3 || parts[0] != 'aes256gcm') {
      throw const FormatException('invalid AES-GCM envelope');
    }
    final nonce = _base64UrlDecode(parts[1]);
    final ciphertext = _base64UrlDecode(parts[2]);
    if (nonce.length != 12 || ciphertext.length < 16) {
      throw const FormatException('invalid AES-GCM envelope lengths');
    }
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(
          KeyParameter(key),
          128,
          nonce,
          Uint8List.fromList(
            utf8.encode(
              sectionWorkspaceCanonicalJson({
                'version': 1,
                'community': community,
                'owner_pubkey': ownerPubkey,
                'section_id': sectionId,
                'key_epoch': keyEpoch,
                'purpose': purpose,
              }),
            ),
          ),
        ),
      );
    return utf8.decode(cipher.process(ciphertext));
  }
}

class SectionWorkspaceKeyEnvelopeCrypto {
  final Uint8List _conversationKey;

  SectionWorkspaceKeyEnvelopeCrypto({
    required String nsec,
    required String ownerPubkey,
  }) : _conversationKey = _conversationKeyFor(nsec, ownerPubkey);

  static Uint8List _conversationKeyFor(String nsec, String ownerPubkey) {
    final privateKey = nostr.Nip19.decode(payload: nsec).data;
    if (privateKey.isEmpty) throw const FormatException('invalid nsec');
    return getConversationKey(privateKey, ownerPubkey);
  }

  String wrap(Uint8List workspaceKey) {
    if (workspaceKey.length != 32) {
      throw ArgumentError('workspace key must be 32 bytes');
    }
    // Desktop wraps the lowercase 64-character key hex. Keep the NIP-44
    // plaintext representation identical across clients.
    return nip44Encrypt(_conversationKey, bytesToHex(workspaceKey));
  }

  Uint8List unwrap(String envelope) {
    final keyHex = nip44Decrypt(_conversationKey, envelope);
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(keyHex)) {
      throw const FormatException('invalid wrapped workspace key');
    }
    return hexToBytes(keyHex);
  }
}

class SectionWorkspaceSyncManager {
  final String ownerPubkey;
  final String? nsec;
  final SharedPreferences prefs;
  final RelaySessionNotifier? relaySession;
  final SignedEventRelay? signedEventRelay;
  final Future<String?> Function()? relaySelfProvider;
  final Future<bool> Function(
    SharedPreferences prefs,
    String ownerPubkey,
    String relayUrl,
    SectionWorkspaceCache cache,
  )?
  cacheWriter;
  final String relayUrl;
  final String relayAuthority;
  final ChannelSectionStore? Function(SectionWorkspaceProjection projection)?
  stageProjection;
  final bool Function(ChannelSectionStore staged)? commitProjection;
  final void Function()? onWorkspaceDiscovered;
  final void Function()? onSubscriptionLost;

  bool _cachePresent = false;
  SectionWorkspaceCache? _cache;
  void Function()? _unsubscribe;
  Future<void>? _subscriptionStartInFlight;
  bool _workspaceKnown = false;
  bool _cacheVerified = false;
  bool _workspaceProbeBlocked = false;
  bool _probeCompleted = false;
  bool _legacyPublishBlocked = false;
  bool _importInFlight = false;
  bool _destroyed = false;
  bool _relayTrustChecked = false;
  bool _relayTrusted = false;
  Future<bool>? _relayTrustInFlight;
  String? _pendingImportSourceEvent;
  String? _pendingImportSourceHash;

  SectionWorkspaceSyncManager({
    required this.ownerPubkey,
    required this.prefs,
    required this.relaySession,
    required this.signedEventRelay,
    this.relaySelfProvider,
    this.cacheWriter,
    required String relayAuthority,
    this.nsec,
    this.stageProjection,
    this.commitProjection,
    this.onWorkspaceDiscovered,
    this.onSubscriptionLost,
  }) : relayUrl = relayAuthority,
       relayAuthority = sectionWorkspaceAuthority(relayAuthority) {
    final cacheKey = sectionWorkspaceCacheKey(ownerPubkey, relayStorageScope);
    _cachePresent = prefs.containsKey(cacheKey);
    _cache = readSectionWorkspaceCache(prefs, ownerPubkey, relayStorageScope);
    if (_cache != null) {
      // A persisted projection is only a candidate until its envelope and
      // metadata authenticate successfully in the current process.
      _workspaceKnown = false;
    }
    _readPendingImport();
  }

  SectionWorkspaceCache? get cache => _cache;
  bool get cachePresent => _cachePresent;
  String get relayStorageScope => sectionWorkspaceStorageScope(relayUrl);
  bool get workspaceKnown => _workspaceKnown;
  bool get subscriptionActive => _unsubscribe != null;
  bool get migrationStarted =>
      _importInFlight ||
      _pendingImportSourceEvent != null ||
      _pendingImportSourceHash != null ||
      _pendingActionId != null;
  bool get legacyReadAllowed =>
      !_workspaceKnown && !_cacheVerified && !migrationStarted;
  bool get probeCompleted => _probeCompleted;
  bool get legacyPublishAllowed =>
      _probeCompleted &&
      !_workspaceKnown &&
      !_workspaceProbeBlocked &&
      !_legacyPublishBlocked;
  bool get hasPendingImport => _legacyPublishBlocked;
  bool isPendingImportSource(String eventId) =>
      migrationStarted && _pendingImportSourceEvent == eventId;

  void markCacheVerified() {
    if (_cache != null) {
      _cacheVerified = true;
      _workspaceKnown = true;
      _legacyPublishBlocked = true;
      onWorkspaceDiscovered?.call();
    }
  }

  Future<bool> _isTrustedRelaySigner(String signer) async {
    final inFlight = _relayTrustInFlight;
    if (inFlight != null) {
      await inFlight;
      return _relayTrusted && signer == _relaySelf;
    }
    if (_relayTrustChecked) {
      return _relayTrusted && signer == _relaySelf;
    }
    final check = _loadRelayTrust();
    _relayTrustInFlight = check;
    try {
      await check;
    } finally {
      if (identical(_relayTrustInFlight, check)) _relayTrustInFlight = null;
    }
    return _relayTrusted && signer == _relaySelf;
  }

  String? _relaySelf;

  Future<bool> _loadRelayTrust() async {
    _relayTrustChecked = true;
    try {
      final self =
          await (relaySelfProvider ??
              () => fetchSectionWorkspaceRelaySelf(relayUrl))();
      final normalized = self?.toLowerCase();
      _relaySelf = normalized;
      _relayTrusted =
          normalized != null && _sectionWorkspaceHex64.hasMatch(normalized);
      _relayTrustChecked = _relayTrusted;
    } catch (_) {
      _relaySelf = null;
      _relayTrusted = false;
      _relayTrustChecked = false;
    }
    return _relayTrusted;
  }

  /// A cache is enough to remain read-compatible while the relay is down. A
  /// successful empty probe is the only condition that permits legacy writes.
  Future<bool> probe() async {
    final session = relaySession;
    if (session == null) return false;
    try {
      final events = await session.fetchHistory(
        NostrFilter(
          kinds: const [sectionWorkspaceProjectionKind],
          tags: {
            '#d': [ownerPubkey],
            '#p': [ownerPubkey],
          },
          limit: 1,
        ),
      );
      NostrEvent? event;
      SectionWorkspaceProjection? projection;
      var sawProjectionEvent = false;
      for (final candidate in events) {
        if (candidate.kind != sectionWorkspaceProjectionKind) continue;
        sawProjectionEvent = true;
        final parsed = _parseEvent(candidate);
        if (parsed == null || !await _isTrustedRelaySigner(candidate.pubkey)) {
          continue;
        }
        event = candidate;
        projection = parsed;
        break;
      }
      _probeCompleted = true;
      if (event == null || projection == null) {
        if (sawProjectionEvent || _cachePresent) {
          // A matching but invalid/undecryptable workspace event or cache is
          // not an empty probe. Fail closed and preserve legacy compatibility
          // only as a read path until a valid projection can be fetched.
          _workspaceProbeBlocked = true;
          _legacyPublishBlocked = true;
          return false;
        }
        return !_workspaceKnown;
      }
      _workspaceProbeBlocked = false;
      final accepted = await _acceptProjection(event, projection);
      if (!accepted) {
        // A syntactically valid projection that cannot be authenticated or
        // decrypted is evidence against legacy writes, but is not itself an
        // authoritative workspace cache.
        _legacyPublishBlocked = true;
      }
      return accepted;
    } catch (_) {
      // A failed authority probe cannot establish that the legacy lane is
      // still safe. Force a fresh probe before allowing any legacy write.
      if (!_workspaceKnown) {
        _probeCompleted = false;
        _workspaceProbeBlocked = true;
        _legacyPublishBlocked = true;
      }
      return false;
    }
  }

  Future<bool> startSubscription() async {
    final session = relaySession;
    if (session == null || _destroyed) return false;
    if (_unsubscribe != null) return true;
    final inFlight = _subscriptionStartInFlight;
    if (inFlight != null) {
      await inFlight;
      return _unsubscribe != null;
    }
    final start = _startSubscription(session);
    _subscriptionStartInFlight = start;
    try {
      return await start;
    } finally {
      if (identical(_subscriptionStartInFlight, start)) {
        _subscriptionStartInFlight = null;
      }
    }
  }

  Future<bool> _startSubscription(RelaySessionNotifier session) async {
    try {
      final unsubscribe = await session.subscribe(
        NostrFilter(
          kinds: const [sectionWorkspaceProjectionKind],
          tags: {
            '#d': [ownerPubkey],
            '#p': [ownerPubkey],
          },
          limit: 0,
        ),
        (event) => _handleProjectionEvent(event),
        onClosed: (_) {
          if (_destroyed) return;
          _unsubscribe = null;
          onSubscriptionLost?.call();
        },
      );
      if (_destroyed) {
        unsubscribe();
        return false;
      }
      _unsubscribe = unsubscribe;
    } catch (_) {
      _unsubscribe = null;
      return false;
    }
    return _unsubscribe != null;
  }

  Future<void> _handleProjectionEvent(NostrEvent event) async {
    if (_destroyed || event.kind != sectionWorkspaceProjectionKind) return;
    final projection = _parseEvent(event);
    if (projection == null) {
      // Do not treat an invalid workspace event as proof that no workspace
      // exists; block legacy writes until a valid projection is observed.
      _legacyPublishBlocked = true;
      return;
    }
    if (!await _isTrustedRelaySigner(event.pubkey)) {
      _legacyPublishBlocked = true;
      return;
    }
    await _handleTrustedProjectionEvent(event, projection);
  }

  Future<void> _handleTrustedProjectionEvent(
    NostrEvent event,
    SectionWorkspaceProjection projection,
  ) async {
    if (!await _isTrustedRelaySigner(event.pubkey)) {
      _legacyPublishBlocked = true;
      return;
    }
    _legacyPublishBlocked = true;
    final previous = _cache?.projection.revision;
    final action = sectionWorkspaceRevisionAction(
      previous,
      projection.revision,
    );
    if (action == SectionWorkspaceRevisionAction.ignore) return;
    if (action == SectionWorkspaceRevisionAction.refetch) {
      await _refetchCurrentProjection();
      return;
    }
    await _acceptProjection(event, projection);
  }

  Future<void> _refetchCurrentProjection() async {
    final session = relaySession;
    if (session == null || _destroyed) return;
    try {
      final events = await session.fetchHistory(
        NostrFilter(
          kinds: const [sectionWorkspaceProjectionKind],
          tags: {
            '#d': [ownerPubkey],
            '#p': [ownerPubkey],
          },
          limit: 1,
        ),
      );
      for (final event in events) {
        if (event.kind != sectionWorkspaceProjectionKind) continue;
        final projection = _parseEvent(event);
        if (projection == null || !await _isTrustedRelaySigner(event.pubkey)) {
          continue;
        }
        await _acceptProjection(event, projection);
        break;
      }
    } catch (_) {
      // Keep the last verified cache when a gap refetch is unavailable.
    }
  }

  SectionWorkspaceProjection? _parseEvent(NostrEvent event) {
    try {
      // NIP-01 event IDs are lowercase SHA-256 hex. Rejecting malformed IDs
      // here keeps source-event identity and the durable cache unambiguous.
      if (!_sectionWorkspaceHex64.hasMatch(event.id)) return null;
      // Relay history/live delivery is transport-authenticated, but the
      // projection is cacheable data. Verify the NIP-01 event before treating
      // it as a last-verified projection.
      if (!verifySectionWorkspaceNostrEvent(event)) return null;
      final projection = parseSectionWorkspaceProjectionJson(event.content);
      if (projection == null || projection.ownerPubkey != ownerPubkey) {
        return null;
      }
      if (event.pubkey.isEmpty ||
          !_sectionWorkspaceHex64.hasMatch(event.pubkey)) {
        return null;
      }
      final dTag = event.getTagValue('d');
      if (dTag != ownerPubkey ||
          event.tags
                  .where(
                    (tag) =>
                        tag.length == 2 &&
                        tag[0] == 'd' &&
                        tag[1] == ownerPubkey,
                  )
                  .length !=
              1 ||
          !event.tags.any(
            (tag) => tag.length >= 2 && tag[0] == 'p' && tag[1] == ownerPubkey,
          )) {
        return null;
      }
      return projection;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _acceptProjection(
    NostrEvent event,
    SectionWorkspaceProjection projection,
  ) async {
    if (_cache != null && projection.revision <= _cache!.projection.revision) {
      return false;
    }
    final staged = stageProjection?.call(projection);
    if (staged == null) return false;
    final cache = SectionWorkspaceCache(
      eventId: event.id,
      projection: projection,
    );
    final persisted = await (cacheWriter ?? writeSectionWorkspaceCache)(
      prefs,
      ownerPubkey,
      relayStorageScope,
      cache,
    );
    if (!persisted) return false;
    // Only a projection whose decrypted metadata and verified cache both made
    // it to durable local storage becomes authoritative. This keeps a cache
    // write failure on the compatibility side of the cutover boundary.
    if (commitProjection?.call(staged) != true) return false;
    _cache = cache;
    _workspaceKnown = true;
    _cacheVerified = true;
    _legacyPublishBlocked = true;
    onWorkspaceDiscovered?.call();
    if (_pendingImportSourceEvent == projection.sourceEventId &&
        _pendingImportSourceHash == projection.sourceHash) {
      await _clearPendingImport();
    }
    return true;
  }

  Future<void> retryPendingImport() async {
    if (_destroyed ||
        _workspaceKnown ||
        _importInFlight ||
        signedEventRelay == null ||
        _pendingImportSourceEvent == null ||
        _pendingImportSourceHash == null) {
      return;
    }
    final body = _readPendingBody(
      _pendingImportSourceEvent!,
      _pendingImportSourceHash!,
    );
    if (body == null) return;
    _importInFlight = true;
    _legacyPublishBlocked = true;
    try {
      await signedEventRelay!.submit(
        kind: sectionWorkspaceImportKind,
        content: sectionWorkspaceCanonicalJson(body),
        tags: [
          ['p', ownerPubkey],
          ['action', body['action_id'] as String],
        ],
      );
      await _refetchCurrentProjection();
    } catch (_) {
      // Keep the byte-identical pending command for the next retry.
      _legacyPublishBlocked = true;
    } finally {
      _importInFlight = false;
    }
  }

  /// Imports the current legacy blob exactly once per persisted action ID. The
  /// pending command is retained so a retry uses byte-identical action bytes.
  Future<void> tryImportLegacy({
    required NostrEvent event,
    required Map<String, dynamic> plaintext,
    required ChannelSectionStore store,
  }) async {
    if (_destroyed ||
        !_probeCompleted ||
        _workspaceProbeBlocked ||
        (_legacyPublishBlocked && !migrationStarted) ||
        _workspaceKnown ||
        nsec == null ||
        signedEventRelay == null ||
        _importInFlight ||
        event.pubkey != ownerPubkey ||
        event.kind != EventKind.readState ||
        !verifySectionWorkspaceNostrEvent(event) ||
        event.getTagValue('d') != 'channel-sections' ||
        event.tags
                .where(
                  (tag) =>
                      tag.length == 2 &&
                      tag[0] == 'd' &&
                      tag[1] == 'channel-sections',
                )
                .length !=
            1 ||
        !_sectionWorkspaceHex64.hasMatch(event.id)) {
      return;
    }
    _importInFlight = true;
    try {
      final acceptedLegacy = parseSectionWorkspaceLegacy(plaintext);
      if (acceptedLegacy == null) return;
      final canonical = sectionWorkspaceCanonicalJson(acceptedLegacy.value);
      final sourceHash = sectionWorkspaceSha256Hex(canonical);
      final hasPendingImport =
          _pendingImportSourceEvent != null ||
          _pendingImportSourceHash != null ||
          _pendingActionId != null;
      if (hasPendingImport &&
          (_pendingImportSourceEvent != event.id ||
              _pendingImportSourceHash != sourceHash)) {
        // Never replace a persisted action with a later legacy source.
        return;
      }
      final pending = _readPendingBody(event.id, sourceHash);
      // Block legacy writes before any asynchronous marker/key work so a
      // concurrent debounce cannot dual-write while the import is built.
      _legacyPublishBlocked = true;
      if (pending == null) {
        // The complete command is the durable cutover intent. Do not persist an
        // action-only marker: without the exact encrypted bytes there is
        // nothing safe to replay after restart.
        final body = await _buildImportBody(
          event,
          sourceHash,
          acceptedLegacy.store,
        );
        if (body == null || _destroyed || _workspaceKnown) return;
        if (parseSectionWorkspaceImport(body) == null) return;
        final canonicalBody = sectionWorkspaceCanonicalJson(body);
        if (!await _writePendingBody(body, canonicalBody: canonicalBody)) {
          // No migration state is entered when persistence fails; a future
          // relay/event pass can safely rebuild and persist the command.
          _legacyPublishBlocked = false;
          return;
        }
      }
      final body = pending ?? _readPendingBody(event.id, sourceHash);
      if (body == null || _destroyed || _workspaceKnown) {
        return;
      }
      if (parseSectionWorkspaceImport(body) == null) {
        return;
      }
      final canonicalBody = sectionWorkspaceCanonicalJson(body);
      try {
        await signedEventRelay!.submit(
          kind: sectionWorkspaceImportKind,
          content: canonicalBody,
          tags: [
            ['p', ownerPubkey],
            ['action', body['action_id'] as String],
          ],
        );
        // The projection/marker is authoritative. Read it back before declaring
        // the cutover complete; a lost read still leaves the exact pending body.
        await _refetchCurrentProjection();
      } catch (_) {
        // A failed publication still leaves the exact command pending. Keep
        // legacy writes blocked until an identical retry reaches the relay.
        _legacyPublishBlocked = true;
      }
    } finally {
      _importInFlight = false;
    }
  }

  Future<Map<String, dynamic>?> _buildImportBody(
    NostrEvent event,
    String sourceHash,
    ChannelSectionStore store,
  ) async {
    final key = secureRandomBytes(32);
    final ownerEnvelope = SectionWorkspaceKeyEnvelopeCrypto(
      nsec: nsec!,
      ownerPubkey: ownerPubkey,
    ).wrap(key);
    final metadata = SectionWorkspaceMetadataCrypto(key);
    final sorted = store.sections.toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    final sections = <Map<String, dynamic>>[];
    for (var rank = 0; rank < sorted.length; rank++) {
      final section = sorted[rank];
      sections.add({
        'id': section.id,
        'rank': rank,
        'encrypted_label': metadata.encrypt(
          plaintext: section.name,
          community: relayAuthority,
          ownerPubkey: ownerPubkey,
          sectionId: section.id,
          keyEpoch: 1,
          purpose: 'label',
        ),
        'encrypted_icon': section.icon == null
            ? null
            : metadata.encrypt(
                plaintext: section.icon!,
                community: relayAuthority,
                ownerPubkey: ownerPubkey,
                sectionId: section.id,
                keyEpoch: 1,
                purpose: 'icon',
              ),
      });
    }
    final actionId = _pendingActionId ?? const Uuid().v4();
    return {
      'version': sectionWorkspaceVersion,
      'action_id': actionId,
      'source_event_id': event.id,
      'source_hash': sourceHash,
      'key_epoch': 1,
      'owner_key_envelope': ownerEnvelope,
      'sections': sections,
      'assignments': [
        for (final entry in store.assignments.entries)
          {'channel_id': entry.key, 'section_id': entry.value},
      ],
    };
  }

  String? _pendingActionId;

  String get _pendingKey =>
      'buzz.section-workspace.pending-import.v1:$ownerPubkey:${Uri.encodeComponent(relayStorageScope)}';

  void _readPendingImport() {
    final raw = prefs.getString(_pendingKey);
    if (raw == null) return;
    try {
      final value = parseSectionWorkspaceJson(raw);
      if (value is! Map<String, dynamic> ||
          !_exactKeys(value, const [
            'source_event_id',
            'source_hash',
            'action_id',
            'canonical',
            'command',
          ]) ||
          value['source_event_id'] is! String ||
          value['source_hash'] is! String ||
          value['action_id'] is! String ||
          value['canonical'] is! String) {
        prefs.remove(_pendingKey);
        return;
      }
      final command = value['command'];
      if (command == null) {
        // Action-only markers cannot satisfy exact replay semantics. Drop the
        // incomplete marker and leave the owner eligible to rebuild the full
        // command from the legacy source event.
        unawaited(prefs.remove(_pendingKey));
        return;
      }
      if (command is! Map<String, dynamic>) {
        prefs.remove(_pendingKey);
        return;
      }
      if (value['source_event_id'] != command['source_event_id'] ||
          value['source_hash'] != command['source_hash'] ||
          value['action_id'] != command['action_id'] ||
          value['canonical'] != sectionWorkspaceCanonicalJson(command) ||
          !_sectionWorkspaceHex64.hasMatch(
            value['source_event_id'] as String,
          ) ||
          !_sectionWorkspaceHex64.hasMatch(value['source_hash'] as String) ||
          parseSectionWorkspaceImport(command) == null) {
        prefs.remove(_pendingKey);
        return;
      }
      _pendingImportSourceEvent = value['source_event_id'] as String;
      _pendingImportSourceHash = value['source_hash'] as String;
      _pendingActionId = value['action_id'] as String;
      _legacyPublishBlocked = true;
    } catch (_) {
      prefs.remove(_pendingKey);
    }
  }

  Map<String, dynamic>? _readPendingBody(
    String sourceEventId,
    String sourceHash,
  ) {
    final raw = prefs.getString(_pendingKey);
    if (raw == null) return null;
    try {
      final value = parseSectionWorkspaceJson(raw);
      if (value is! Map<String, dynamic> ||
          !_exactKeys(value, const [
            'source_event_id',
            'source_hash',
            'action_id',
            'canonical',
            'command',
          ]) ||
          value['command'] is! Map<String, dynamic>) {
        return null;
      }
      final command = value['command'] as Map<String, dynamic>;
      if (value['source_event_id'] != sourceEventId ||
          value['source_hash'] != sourceHash ||
          value['source_event_id'] != command['source_event_id'] ||
          value['source_hash'] != command['source_hash'] ||
          value['action_id'] != command['action_id'] ||
          value['canonical'] is! String ||
          value['canonical'] != sectionWorkspaceCanonicalJson(command) ||
          parseSectionWorkspaceImport(command) == null) {
        return null;
      }
      return command;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _writePendingBody(
    Map<String, dynamic> body, {
    required String canonicalBody,
  }) async {
    final sourceEvent = body['source_event_id'] as String;
    final sourceHash = body['source_hash'] as String;
    final actionId = body['action_id'] as String;
    final persisted = await prefs.setString(
      _pendingKey,
      jsonEncode({
        'source_event_id': sourceEvent,
        'source_hash': sourceHash,
        'action_id': actionId,
        'canonical': canonicalBody,
        'command': body,
      }),
    );
    if (!persisted) return false;
    // Do not enter the one-way migration state until the complete command is
    // durably stored. A failed write must leave this process retryable and
    // must never publish bytes that cannot be replayed after restart.
    _pendingActionId = actionId;
    _pendingImportSourceEvent = sourceEvent;
    _pendingImportSourceHash = sourceHash;
    return true;
  }

  Future<void> _clearPendingImport() async {
    _pendingActionId = null;
    _pendingImportSourceEvent = null;
    _pendingImportSourceHash = null;
    await prefs.remove(_pendingKey);
    _legacyPublishBlocked = false;
  }

  void dispose() {
    _destroyed = true;
    _unsubscribe?.call();
    _unsubscribe = null;
  }
}

int _compareUnicodeCodePoints(String left, String right) {
  final leftRunes = left.runes.toList();
  final rightRunes = right.runes.toList();
  final count = leftRunes.length < rightRunes.length
      ? leftRunes.length
      : rightRunes.length;
  for (var index = 0; index < count; index++) {
    final comparison = leftRunes[index].compareTo(rightRunes[index]);
    if (comparison != 0) return comparison;
  }
  return leftRunes.length.compareTo(rightRunes.length);
}

bool _exactKeys(Map<String, dynamic> object, List<String> keys) {
  if (object.length != keys.length) return false;
  return keys.every(object.containsKey);
}

bool _validCiphertext(String value, int maximumBytes) {
  final length = utf8.encode(value).length;
  return value.isNotEmpty && length <= maximumBytes;
}

bool _allJsonNumbersAreIntegers(Object? value) {
  if (value is num) return value is int;
  if (value is List) return value.every(_allJsonNumbersAreIntegers);
  if (value is Map) return value.values.every(_allJsonNumbersAreIntegers);
  return true;
}

String _base64UrlNoPad(Uint8List bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

Uint8List _base64UrlDecode(String value) =>
    Uint8List.fromList(base64Url.decode(base64Url.normalize(value)));

bool _hasDuplicateJsonObjectKeys(String source) {
  var index = 0;
  void whitespace() {
    while (index < source.length && ' \t\r\n'.contains(source[index])) {
      index++;
    }
  }

  void stringValue() {
    if (source[index] != '"') {
      throw const FormatException('expected JSON string');
    }
    index++;
    while (index < source.length) {
      final char = source[index++];
      if (char == '\\') {
        if (index >= source.length) {
          throw const FormatException('bad JSON escape');
        }
        final escaped = source[index++];
        if (escaped == 'u') {
          if (index + 4 > source.length ||
              !RegExp(
                r'^[0-9a-fA-F]{4}$',
              ).hasMatch(source.substring(index, index + 4))) {
            throw const FormatException('bad JSON unicode escape');
          }
          index += 4;
        }
      } else if (char == '"') {
        return;
      } else if (char.codeUnitAt(0) < 0x20) {
        throw const FormatException('bad JSON string');
      }
    }
    throw const FormatException('unterminated JSON string');
  }

  bool value() {
    whitespace();
    if (index >= source.length) {
      throw const FormatException('missing JSON value');
    }
    switch (source[index]) {
      case '"':
        stringValue();
      case '{':
        index++;
        whitespace();
        final keys = <String>{};
        if (index < source.length && source[index] == '}') {
          index++;
          return false;
        }
        while (true) {
          whitespace();
          final start = index;
          stringValue();
          final key = jsonDecode(source.substring(start, index)) as String;
          if (!keys.add(key)) return true;
          whitespace();
          if (index >= source.length || source[index++] != ':') {
            throw const FormatException('missing JSON colon');
          }
          if (value()) return true;
          whitespace();
          if (index >= source.length) {
            throw const FormatException('unterminated JSON object');
          }
          final separator = source[index++];
          if (separator == '}') break;
          if (separator != ',') {
            throw const FormatException('invalid JSON object');
          }
        }
      case '[':
        index++;
        whitespace();
        if (index < source.length && source[index] == ']') {
          index++;
          return false;
        }
        while (true) {
          if (value()) return true;
          whitespace();
          if (index >= source.length) {
            throw const FormatException('unterminated JSON array');
          }
          final separator = source[index++];
          if (separator == ']') break;
          if (separator != ',') {
            throw const FormatException('invalid JSON array');
          }
        }
      default:
        final start = index;
        while (index < source.length && !' \t\r\n,]}'.contains(source[index])) {
          index++;
        }
        if (start == index) throw const FormatException('invalid JSON value');
    }
    return false;
  }

  final duplicate = value();
  whitespace();
  if (index != source.length) throw const FormatException('trailing JSON data');
  return duplicate;
}
