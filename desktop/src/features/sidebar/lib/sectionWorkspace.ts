import { bytesToHex } from "@noble/hashes/utils.js";
import { sha256 } from "@noble/hashes/sha2.js";
import { verifyEvent } from "nostr-tools/pure";

import { relayClient } from "@/shared/api/relayClient";
import {
  nip44DecryptFromSelf,
  nip44EncryptToSelf,
  signRelayEvent,
} from "@/shared/api/tauri";
import {
  generateWorkspaceKey,
  encryptWorkspaceMetadata,
  decryptWorkspaceMetadata,
} from "@/shared/api/workspaceCrypto";

import type { RelayEvent } from "@/shared/api/types";
import type { LegacySectionSource } from "./channelSectionsSync";
import { getRelaySelf } from "@/features/moderation/lib/relaySelf";
import { normalizeRelayUrl } from "@/shared/lib/normalizeRelayUrl";
import {
  hasImportMarker,
  readStoredImportAction,
  readStoredImportCommand,
  clearImportAction,
  writeImportState,
} from "./sectionWorkspaceStorage";
import {
  KIND_SECTION_WORKSPACE_IMPORT,
  KIND_SECTION_WORKSPACE_PROJECTION,
} from "./sectionWorkspaceKinds";
import type {
  ChannelSectionStore,
  ChannelSection,
} from "./channelSectionsStorage";
import {
  boundChannelSectionsStore,
  parseChannelSectionPayload,
} from "./channelSectionsStorage";

export const SECTION_WORKSPACE_VERSION = 1;
const MAX_SECTIONS = 100;
const MAX_ASSIGNMENTS = 1_000;
const MAX_ENCRYPTED_METADATA_BYTES = 65_535;
const MAX_KEY_ENVELOPE_BYTES = 4_096;
const CACHE_PREFIX = "buzz-section-workspace.v1";
class UntrustedProjectionError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "UntrustedProjectionError";
  }
}
type ProjectionSection = {
  id: string;
  rank: number;
  encrypted_label: string;
  encrypted_icon: string | null;
};
type ProjectionAssignment = {
  channel_id: string;
  section_id: string;
  revision: number;
};
export type SectionWorkspaceProjection = {
  version: 1;
  owner_pubkey: string;
  revision: number;
  layout_revision: number;
  key_epoch: number;
  migration: { source_event_id: string; source_hash: string };
  reader_key_envelope: string;
  sections: ProjectionSection[];
  assignments: ProjectionAssignment[];
};
export type WorkspaceCache = {
  projection: SectionWorkspaceProjection;
  store: ChannelSectionStore;
  revision: number;
  keyEpoch: number;
};

type ImportSection = {
  id: string;
  rank: number;
  encrypted_label: string;
  encrypted_icon: string | null;
};
type ImportAssignment = { channel_id: string; section_id: string };
type WorkspaceImport = {
  version: 1;
  action_id: string;
  source_event_id: string;
  source_hash: string;
  key_epoch: 1;
  owner_key_envelope: string;
  sections: ImportSection[];
  assignments: ImportAssignment[];
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function rejectDuplicateJsonKeys(input: string): void {
  let index = 0;
  const skipWhitespace = () => {
    while (/\s/.test(input[index] ?? "")) index += 1;
  };
  const parseString = (): string => {
    const start = index;
    if (input[index] !== '"') throw new Error("invalid JSON");
    index += 1;
    while (index < input.length) {
      const character = input[index++];
      if (character === "\\") {
        index += 1;
      } else if (character === '"') {
        return JSON.parse(input.slice(start, index)) as string;
      }
    }
    throw new Error("invalid JSON string");
  };
  const parseValue = (): void => {
    skipWhitespace();
    const character = input[index];
    if (character === "{") {
      index += 1;
      skipWhitespace();
      const keys = new Set<string>();
      if (input[index] === "}") {
        index += 1;
        return;
      }
      while (index < input.length) {
        skipWhitespace();
        const key = parseString();
        if (keys.has(key)) throw new Error("duplicate JSON key");
        keys.add(key);
        skipWhitespace();
        if (input[index++] !== ":") throw new Error("invalid JSON object");
        parseValue();
        skipWhitespace();
        if (input[index] === "}") {
          index += 1;
          return;
        }
        if (input[index++] !== ",") throw new Error("invalid JSON object");
      }
      throw new Error("invalid JSON object");
    }
    if (character === "[") {
      index += 1;
      skipWhitespace();
      if (input[index] === "]") {
        index += 1;
        return;
      }
      while (index < input.length) {
        parseValue();
        skipWhitespace();
        if (input[index] === "]") {
          index += 1;
          return;
        }
        if (input[index++] !== ",") throw new Error("invalid JSON array");
      }
      throw new Error("invalid JSON array");
    }
    if (character === '"') {
      parseString();
      return;
    }
    const start = index;
    while (index < input.length && !/[\s,\]}]/.test(input[index] ?? ""))
      index += 1;
    if (start === index) throw new Error("invalid JSON value");
  };
  parseValue();
  skipWhitespace();
  if (index !== input.length) throw new Error("invalid JSON trailing data");
}

export function parseStrictJson(input: string): unknown {
  rejectDuplicateJsonKeys(input);
  return JSON.parse(input) as unknown;
}

function exactKeys(
  value: Record<string, unknown>,
  keys: readonly string[],
): boolean {
  const expected = new Set(keys);
  return (
    Object.keys(value).length === expected.size &&
    Object.keys(value).every((key) => expected.has(key))
  );
}
function integerField(value: Record<string, unknown>, key: string): number {
  const result = value[key];
  if (typeof result !== "number" || !Number.isSafeInteger(result) || result < 0)
    throw new Error(`invalid ${key}`);
  return result;
}
function uuid(value: unknown, key: string): string {
  if (
    typeof value !== "string" ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(
      value,
    )
  )
    throw new Error(`invalid ${key}`);
  return value;
}
function lowercaseHex64(value: unknown, key: string): string {
  if (typeof value !== "string" || !/^[0-9a-f]{64}$/.test(value))
    throw new Error(`invalid ${key}`);
  return value;
}
function positiveIntegerField(
  value: Record<string, unknown>,
  key: string,
): number {
  const result = integerField(value, key);
  if (result < 1) throw new Error(`invalid ${key}`);
  return result;
}
function boundedUtf8String(
  value: unknown,
  key: string,
  maxBytes: number,
): string {
  if (typeof value !== "string" || value.length === 0)
    throw new Error(`invalid ${key}`);
  if (new TextEncoder().encode(value).byteLength > maxBytes)
    throw new Error(`${key} exceeds size limit`);
  return value;
}

export function parseSectionWorkspaceProjection(
  input: unknown,
): SectionWorkspaceProjection {
  if (
    !isRecord(input) ||
    !exactKeys(input, [
      "version",
      "owner_pubkey",
      "revision",
      "layout_revision",
      "key_epoch",
      "migration",
      "reader_key_envelope",
      "sections",
      "assignments",
    ])
  )
    throw new Error("invalid projection fields");
  if (input.version !== SECTION_WORKSPACE_VERSION)
    throw new Error("unsupported projection version");
  const migration = input.migration;
  if (
    !isRecord(migration) ||
    !exactKeys(migration, ["source_event_id", "source_hash"])
  )
    throw new Error("invalid migration marker");
  const sectionsInput = input.sections;
  const assignmentsInput = input.assignments;
  if (
    !Array.isArray(sectionsInput) ||
    sectionsInput.length > MAX_SECTIONS ||
    !Array.isArray(assignmentsInput) ||
    assignmentsInput.length > MAX_ASSIGNMENTS
  )
    throw new Error("projection limits exceeded");
  const sections = sectionsInput.map((raw, index) => {
    if (
      !isRecord(raw) ||
      !exactKeys(raw, ["id", "rank", "encrypted_label", "encrypted_icon"])
    )
      throw new Error(`invalid section ${index}`);
    const icon = raw.encrypted_icon;
    if (icon !== null && typeof icon !== "string")
      throw new Error("invalid encrypted_icon");
    return {
      id: uuid(raw.id, "section id"),
      rank: integerField(raw, "rank"),
      encrypted_label: boundedUtf8String(
        raw.encrypted_label,
        "encrypted_label",
        MAX_ENCRYPTED_METADATA_BYTES,
      ),
      encrypted_icon:
        icon === null
          ? null
          : boundedUtf8String(
              icon,
              "encrypted_icon",
              MAX_ENCRYPTED_METADATA_BYTES,
            ),
    };
  });
  const ids = new Set(sections.map((section) => section.id));
  if (ids.size !== sections.length) throw new Error("duplicate section id");
  const ranks = new Set(sections.map((section) => section.rank));
  if (
    ranks.size !== sections.length ||
    sections.some((section) => section.rank >= sections.length)
  )
    throw new Error("invalid section ranks");
  const assignments = assignmentsInput.map((raw, index) => {
    if (
      !isRecord(raw) ||
      !exactKeys(raw, ["channel_id", "section_id", "revision"])
    )
      throw new Error(`invalid assignment ${index}`);
    const assignment = {
      channel_id: uuid(raw.channel_id, "channel id"),
      section_id: uuid(raw.section_id, "section id"),
      revision: integerField(raw, "revision"),
    };
    if (!ids.has(assignment.section_id))
      throw new Error("assignment references unknown section");
    return assignment;
  });
  if (
    new Set(assignments.map((assignment) => assignment.channel_id)).size !==
    assignments.length
  )
    throw new Error("duplicate channel assignment");
  return {
    version: 1,
    owner_pubkey: lowercaseHex64(input.owner_pubkey, "owner_pubkey"),
    revision: integerField(input, "revision"),
    layout_revision: integerField(input, "layout_revision"),
    key_epoch: positiveIntegerField(input, "key_epoch"),
    migration: {
      source_event_id: lowercaseHex64(
        migration.source_event_id,
        "source_event_id",
      ),
      source_hash: lowercaseHex64(migration.source_hash, "source_hash"),
    },
    reader_key_envelope: boundedUtf8String(
      input.reader_key_envelope,
      "reader_key_envelope",
      MAX_KEY_ENVELOPE_BYTES,
    ),
    sections,
    assignments,
  };
}
function parseWorkspaceImport(input: unknown): WorkspaceImport {
  if (
    !isRecord(input) ||
    !exactKeys(input, [
      "version",
      "action_id",
      "source_event_id",
      "source_hash",
      "key_epoch",
      "owner_key_envelope",
      "sections",
      "assignments",
    ]) ||
    input.version !== SECTION_WORKSPACE_VERSION ||
    input.key_epoch !== 1
  )
    throw new Error("invalid workspace import fields");
  const sectionsInput = input.sections;
  const assignmentsInput = input.assignments;
  if (
    !Array.isArray(sectionsInput) ||
    sectionsInput.length > MAX_SECTIONS ||
    !Array.isArray(assignmentsInput) ||
    assignmentsInput.length > MAX_ASSIGNMENTS
  )
    throw new Error("workspace import limits exceeded");
  const sections = sectionsInput.map((raw, index) => {
    if (
      !isRecord(raw) ||
      !exactKeys(raw, ["id", "rank", "encrypted_label", "encrypted_icon"])
    )
      throw new Error(`invalid import section ${index}`);
    const icon = raw.encrypted_icon;
    if (icon !== null && typeof icon !== "string")
      throw new Error("invalid import encrypted_icon");
    return {
      id: uuid(raw.id, "section id"),
      rank: integerField(raw, "rank"),
      encrypted_label: boundedUtf8String(
        raw.encrypted_label,
        "encrypted_label",
        MAX_ENCRYPTED_METADATA_BYTES,
      ),
      encrypted_icon:
        icon === null
          ? null
          : boundedUtf8String(
              icon,
              "encrypted_icon",
              MAX_ENCRYPTED_METADATA_BYTES,
            ),
    };
  });
  const ids = new Set(sections.map((section) => section.id));
  const ranks = new Set(sections.map((section) => section.rank));
  if (
    ids.size !== sections.length ||
    ranks.size !== sections.length ||
    sections.some((section) => section.rank >= sections.length)
  )
    throw new Error("invalid import section shape");
  const assignments = assignmentsInput.map((raw, index) => {
    if (!isRecord(raw) || !exactKeys(raw, ["channel_id", "section_id"]))
      throw new Error(`invalid import assignment ${index}`);
    const assignment = {
      channel_id: uuid(raw.channel_id, "channel id"),
      section_id: uuid(raw.section_id, "section id"),
    };
    if (!ids.has(assignment.section_id))
      throw new Error("assignment references unknown section");
    return assignment;
  });
  if (
    new Set(assignments.map((assignment) => assignment.channel_id)).size !==
    assignments.length
  )
    throw new Error("duplicate import channel assignment");
  return {
    version: 1,
    action_id: uuid(input.action_id, "action_id"),
    source_event_id: lowercaseHex64(input.source_event_id, "source_event_id"),
    source_hash: lowercaseHex64(input.source_hash, "source_hash"),
    key_epoch: 1,
    owner_key_envelope: boundedUtf8String(
      input.owner_key_envelope,
      "owner_key_envelope",
      MAX_KEY_ENVELOPE_BYTES,
    ),
    sections,
    assignments,
  };
}
export function projectionRevisionAction(
  previous: number | null,
  incoming: number,
): "accept" | "refetch" | "ignore" {
  if (previous === null || incoming === previous + 1) return "accept";
  if (incoming <= (previous ?? -1)) return "ignore";
  return "refetch";
}
function compareCodePoints(left: string, right: string): number {
  const leftPoints = Array.from(
    left,
    (character) => character.codePointAt(0) ?? 0,
  );
  const rightPoints = Array.from(
    right,
    (character) => character.codePointAt(0) ?? 0,
  );
  for (
    let index = 0;
    index < Math.min(leftPoints.length, rightPoints.length);
    index++
  ) {
    if (leftPoints[index] !== rightPoints[index])
      return leftPoints[index] - rightPoints[index];
  }
  return leftPoints.length - rightPoints.length;
}

export function canonicalJson(input: unknown): string {
  if (input === null || typeof input === "boolean" || typeof input === "string")
    return JSON.stringify(input);
  if (typeof input === "number") {
    if (!Number.isSafeInteger(input))
      throw new Error("canonical JSON only permits integer numbers");
    return String(input);
  }
  if (Array.isArray(input)) return `[${input.map(canonicalJson).join(",")}]`;
  if (!isRecord(input)) throw new Error("invalid JSON value");
  return `{${Object.keys(input)
    .sort(compareCodePoints)
    .map((key) => `${JSON.stringify(key)}:${canonicalJson(input[key])}`)
    .join(",")}}`;
}
export function canonicalRelayAuthority(relayUrl: string): string {
  const parsed = new URL(relayUrl.trim());
  if (
    !["ws:", "wss:", "http:", "https:"].includes(parsed.protocol) ||
    !parsed.hostname
  ) {
    throw new Error("invalid relay URL");
  }
  return parsed.host.toLowerCase();
}

function cacheKey(pubkey: string, relayUrl: string): string {
  return `${CACHE_PREFIX}:${pubkey}:${encodeURIComponent(normalizeRelayUrl(relayUrl))}`;
}
function readCache(pubkey: string, relayUrl: string): WorkspaceCache | null {
  try {
    const raw = window.localStorage.getItem(cacheKey(pubkey, relayUrl));
    if (!raw) return null;
    const parsed = parseStrictJson(raw) as {
      projection: unknown;
      store: unknown;
      revision: number;
      keyEpoch: number;
    };
    const projection = parseSectionWorkspaceProjection(parsed.projection);
    if (
      !projection ||
      !isRecord(parsed.store) ||
      parsed.revision !== projection.revision ||
      parsed.keyEpoch !== projection.key_epoch
    )
      return null;
    const store = parseChannelSectionPayload(parsed.store);
    if (!store) return null;
    return {
      projection,
      store,
      revision: parsed.revision,
      keyEpoch: parsed.keyEpoch,
    };
  } catch {
    return null;
  }
}
function writeCache(
  pubkey: string,
  relayUrl: string,
  cache: WorkspaceCache,
  store: ChannelSectionStore,
): void {
  try {
    window.localStorage.setItem(
      cacheKey(pubkey, relayUrl),
      JSON.stringify({ ...cache, store }),
    );
  } catch {}
}
export function canonicalMetadataAad(
  community: string,
  owner: string,
  sectionId: string,
  epoch: number,
  purpose: "label" | "icon",
): string {
  return canonicalJson({
    version: 1,
    community: canonicalRelayAuthority(community),
    owner_pubkey: owner,
    section_id: sectionId,
    key_epoch: epoch,
    purpose,
  });
}
function outputWithinLimit(
  value: string,
  key: string,
  maxBytes: number,
): string {
  if (new TextEncoder().encode(value).byteLength > maxBytes)
    throw new Error(`${key} exceeds size limit`);
  return value;
}

async function encryptMetadata(
  key: string,
  community: string,
  owner: string,
  section: ChannelSection,
  purpose: "label" | "icon",
  value: string,
): Promise<string> {
  return outputWithinLimit(
    await encryptWorkspaceMetadata({
      keyHex: key,
      plaintext: value,
      aad: canonicalMetadataAad(community, owner, section.id, 1, purpose),
    }),
    "encrypted_metadata",
    MAX_ENCRYPTED_METADATA_BYTES,
  );
}
async function decryptMetadata(
  key: string,
  community: string,
  owner: string,
  sectionId: string,
  epoch: number,
  purpose: "label" | "icon",
  value: string,
): Promise<string> {
  return decryptWorkspaceMetadata({
    keyHex: key,
    envelope: value,
    aad: canonicalMetadataAad(community, owner, sectionId, epoch, purpose),
  });
}
async function projectionStore(
  projection: SectionWorkspaceProjection,
  key: string,
  community: string,
): Promise<ChannelSectionStore> {
  const sections: ChannelSection[] = [];
  for (const projected of projection.sections
    .slice()
    .sort((left, right) => left.rank - right.rank)) {
    const name = await decryptMetadata(
      key,
      community,
      projection.owner_pubkey,
      projected.id,
      projection.key_epoch,
      "label",
      projected.encrypted_label,
    );
    const icon = projected.encrypted_icon
      ? await decryptMetadata(
          key,
          community,
          projection.owner_pubkey,
          projected.id,
          projection.key_epoch,
          "icon",
          projected.encrypted_icon,
        )
      : undefined;
    sections.push({
      id: projected.id,
      name,
      order: projected.rank,
      ...(icon ? { icon } : {}),
    });
  }
  return boundChannelSectionsStore({
    version: 1,
    sections,
    assignments: Object.fromEntries(
      projection.assignments.map((assignment) => [
        assignment.channel_id,
        assignment.section_id,
      ]),
    ),
  });
}

function validateEventRouting(event: RelayEvent, owner: string): void {
  const ownerTags = event.tags.filter(
    (tag) => tag.length === 2 && tag[0] === "p" && tag[1] === owner,
  );
  const addressTags = event.tags.filter(
    (tag) => tag.length === 2 && tag[0] === "d" && tag[1] === owner,
  );
  if (event.kind !== KIND_SECTION_WORKSPACE_PROJECTION) {
    throw new Error("invalid projection kind");
  }
  if (ownerTags.length < 1 || addressTags.length !== 1)
    throw new Error("projection routing mismatch");
}

async function projectionFromEvent(
  event: RelayEvent,
  owner: string,
): Promise<SectionWorkspaceProjection> {
  if (
    event.id.length !== 64 ||
    !/^[0-9a-f]{64}$/.test(event.id) ||
    event.pubkey.length !== 64 ||
    !/^[0-9a-f]{64}$/.test(event.pubkey) ||
    !verifyEvent({
      id: event.id,
      pubkey: event.pubkey,
      created_at: event.created_at,
      kind: event.kind,
      tags: event.tags,
      content: event.content,
      sig: event.sig,
    })
  )
    throw new Error("invalid projection event signature");
  let relaySelf: string | null;
  try {
    relaySelf = await getRelaySelf();
  } catch {
    throw new UntrustedProjectionError("relay signer is untrusted");
  }
  if (!relaySelf || relaySelf !== event.pubkey)
    throw new UntrustedProjectionError("invalid projection relay signer");
  const projection = parseSectionWorkspaceProjection(
    parseStrictJson(event.content),
  );
  if (projection.owner_pubkey !== owner)
    throw new Error("invalid projection owner");
  validateEventRouting(event, owner);
  return projection;
}

async function fetchProjection(
  pubkey: string,
): Promise<SectionWorkspaceProjection | null> {
  const events = await relayClient.fetchEvents({
    kinds: [KIND_SECTION_WORKSPACE_PROJECTION],
    "#d": [pubkey],
    "#p": [pubkey],
    limit: 1,
  });
  if (events.length === 0) return null;
  const event = events[0];
  return projectionFromEvent(event, pubkey);
}

async function publishImportCommand(
  pubkey: string,
  actionId: string,
  command: string,
): Promise<void> {
  const event = await signRelayEvent({
    kind: KIND_SECTION_WORKSPACE_IMPORT,
    content: command,
    tags: [
      ["p", pubkey],
      ["action", actionId],
    ],
  });
  await relayClient.publishEvent(
    event,
    "Timed out importing channel sections.",
    "Failed to import channel sections.",
  );
}

async function replayStoredImport(
  pubkey: string,
  relayUrl: string,
): Promise<boolean> {
  const command = readStoredImportCommand(pubkey, normalizeRelayUrl(relayUrl));
  if (!command) return false;
  const parsed = parseStrictJson(command) as { action_id?: unknown };
  if (typeof parsed.action_id !== "string")
    throw new Error("stored import command has no action id");
  parseWorkspaceImport(parsed);
  await publishImportCommand(pubkey, parsed.action_id, command);
  return true;
}

async function submitImport(
  pubkey: string,
  relayUrl: string,
  legacy: RelayEvent,
  plaintext: string,
  store: ChannelSectionStore,
): Promise<void> {
  if (legacy.id.length !== 64 || !/^[0-9a-f]{64}$/.test(legacy.id))
    throw new Error("invalid legacy source event");
  if (legacy.pubkey !== pubkey) throw new Error("invalid legacy source signer");
  const normalizedRelay = normalizeRelayUrl(relayUrl);
  const canonicalPlaintext = canonicalJson(parseStrictJson(plaintext));
  const sourceHash = bytesToHex(
    sha256(new TextEncoder().encode(canonicalPlaintext)),
  );
  let actionId: string;
  let command: string | null = readStoredImportCommand(pubkey, normalizedRelay);
  if (command) {
    const parsed = parseStrictJson(command);
    const imported = parseWorkspaceImport(parsed);
    actionId = imported.action_id;
  } else {
    actionId =
      readStoredImportAction(pubkey, normalizedRelay) ?? crypto.randomUUID();
    const key = await generateWorkspaceKey();
    const sections: ImportSection[] = [];
    const sectionIds = new Set<string>();
    const sectionIdByLegacyId = new Map<string, string>();
    for (const [index, section] of store.sections
      .slice()
      .sort((left, right) => left.order - right.order)
      .entries()) {
      const sectionId = uuid(section.id, "section id");
      if (sectionIds.has(sectionId)) throw new Error("duplicate section id");
      sectionIds.add(sectionId);
      sectionIdByLegacyId.set(section.id, sectionId);
      sections.push({
        id: sectionId,
        rank: index,
        encrypted_label: await encryptMetadata(
          key,
          normalizedRelay,
          pubkey,
          section,
          "label",
          section.name,
        ),
        encrypted_icon: section.icon
          ? await encryptMetadata(
              key,
              normalizedRelay,
              pubkey,
              section,
              "icon",
              section.icon,
            )
          : null,
      });
    }
    const assignments = Object.entries(store.assignments).map(
      ([channel_id, section_id]) => ({
        channel_id: uuid(channel_id, "channel id"),
        section_id:
          sectionIdByLegacyId.get(uuid(section_id, "section id")) ??
          (() => {
            throw new Error("assignment references unknown section");
          })(),
      }),
    );
    const imported: WorkspaceImport = {
      version: 1,
      action_id: actionId,
      source_event_id: legacy.id,
      source_hash: sourceHash,
      key_epoch: 1,
      owner_key_envelope: await nip44EncryptToSelf(key),
      sections,
      assignments,
    };
    command = canonicalJson(imported);
    parseWorkspaceImport(parseStrictJson(command));
    if (!writeImportState(pubkey, normalizedRelay, actionId, command)) {
      throw new Error("cannot durably persist workspace import command");
    }
  }
  await publishImportCommand(pubkey, actionId, command);
}

export class SectionWorkspaceSyncManager {
  private destroyed = false;
  private migrationStarted: boolean;
  private projection: SectionWorkspaceProjection | null;
  private cached: WorkspaceCache | null;
  private readonly pubkey: string;
  private workspaceProbeBlocked = false;
  private readonly relayUrl: string;

  constructor(pubkey: string, relayUrl: string) {
    this.pubkey = pubkey;
    this.relayUrl = relayUrl;
    this.cached = readCache(pubkey, relayUrl);
    this.projection = this.cached?.projection ?? null;
    this.migrationStarted = hasImportMarker(pubkey, relayUrl);
  }
  getCachedStore(): ChannelSectionStore | null {
    return this.cached?.store ?? null;
  }
  isCanonical(): boolean {
    return (
      this.projection !== null ||
      this.migrationStarted ||
      this.workspaceProbeBlocked
    );
  }
  cancelLegacyPublish(): void {
    // The legacy manager is owned by the hook; this marker lets the hook stop
    // a debounced whole-blob write once the relay projection is authoritative.
    this.migrationStarted = true;
  }
  private async acceptProjection(
    projection: SectionWorkspaceProjection,
  ): Promise<ChannelSectionStore> {
    this.projection = projection;
    const key = await nip44DecryptFromSelf(projection.reader_key_envelope);
    const store = await projectionStore(
      projection,
      key,
      normalizeRelayUrl(this.relayUrl),
    );
    this.cached = {
      projection,
      store,
      revision: projection.revision,
      keyEpoch: projection.key_epoch,
    };
    writeCache(this.pubkey, this.relayUrl, this.cached, store);
    return store;
  }
  async bootstrap(
    legacyFetch: () => Promise<LegacySectionSource | null>,
  ): Promise<ChannelSectionStore | null> {
    try {
      const projection = await fetchProjection(this.pubkey);
      if (projection) {
        const action = projectionRevisionAction(
          this.projection?.revision ?? null,
          projection.revision,
        );
        if (action === "ignore") return this.getCachedStore();
        if (action === "refetch") {
          const refreshed = await fetchProjection(this.pubkey);
          if (
            !refreshed ||
            refreshed.revision <= (this.projection?.revision ?? -1)
          )
            return this.getCachedStore();
          return this.acceptProjection(refreshed);
        }
        return this.acceptProjection(projection);
      }
      if (this.migrationStarted) {
        const command = readStoredImportCommand(this.pubkey, this.relayUrl);
        if (command) {
          const replayed = await replayStoredImport(this.pubkey, this.relayUrl);
          if (replayed) return this.getCachedStore();
        }
        const actionOnly = readStoredImportAction(this.pubkey, this.relayUrl);
        if (actionOnly && clearImportAction(this.pubkey, this.relayUrl)) {
          this.migrationStarted = false;
        } else {
          return this.getCachedStore();
        }
      }
      if (this.pubkey && !this.destroyed) {
        const legacy = await legacyFetch();
        if (legacy) {
          this.migrationStarted = true;
          await submitImport(
            this.pubkey,
            this.relayUrl,
            legacy.event,
            legacy.plaintext,
            legacy.store,
          );
        }
      }
    } catch (error) {
      if (!(error instanceof UntrustedProjectionError)) {
        this.workspaceProbeBlocked = true;
      }
    }
    return this.cached ? this.getCachedStore() : null;
  }
  async subscribe(
    onStore: (store: ChannelSectionStore) => void,
  ): Promise<() => Promise<void>> {
    return relayClient.subscribeLive(
      {
        kinds: [KIND_SECTION_WORKSPACE_PROJECTION],
        "#d": [this.pubkey],
        "#p": [this.pubkey],
        limit: 0,
      },
      (event) => {
        if (this.destroyed) return;
        void (async () => {
          try {
            let remote = await projectionFromEvent(event, this.pubkey);
            let action = projectionRevisionAction(
              this.projection?.revision ?? null,
              remote.revision,
            );
            if (action === "refetch") {
              const fetched = await fetchProjection(this.pubkey);
              if (
                !fetched ||
                fetched.revision <= (this.projection?.revision ?? -1)
              )
                return;
              remote = fetched;
              action = "accept";
            }
            if (action !== "accept") return;
            const store = await this.acceptProjection(remote);
            onStore(store);
          } catch (error) {
            if (!(error instanceof UntrustedProjectionError)) {
              this.workspaceProbeBlocked = true;
            }
          }
        })();
      },
    );
  }
  destroy(): void {
    this.destroyed = true;
  }
}
