import assert from "node:assert/strict";
import { after, before, test } from "node:test";

import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  url: "http://localhost",
});

before(() => {
  Object.assign(globalThis, {
    document: dom.window.document,
    HTMLElement: dom.window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
    window: dom.window,
  });
});

after(() => dom.window.close());

test("assignChannel refreshes an existing assignment before the next eviction", async () => {
  const { act, cleanup, renderHook } = await import("@testing-library/react");
  const { relayClient } = await import("@/shared/api/relayClient");
  const { MAX_CHANNEL_SECTION_ASSIGNMENTS, storageKey } = await import(
    "./channelSectionsStorage.ts"
  );
  const { useChannelSections } = await import("./useChannelSections.ts");

  const originalFetchEvents = relayClient.fetchEvents;
  const originalSubscribeLive = relayClient.subscribeLive;
  const originalSubscribeToReconnects = relayClient.subscribeToReconnects;
  relayClient.fetchEvents = async () => [];
  relayClient.subscribeLive = async () => async () => {};
  relayClient.subscribeToReconnects = () => () => {};

  const pubkey = "pk-at-capacity";
  const relayUrl = "wss://relay.example";
  const assignments = Object.fromEntries(
    Array.from({ length: MAX_CHANNEL_SECTION_ASSIGNMENTS }, (_, index) => [
      `chan-${String(index).padStart(4, "0")}`,
      "section-1",
    ]),
  );
  window.localStorage.setItem(
    storageKey(pubkey, relayUrl),
    JSON.stringify({
      version: 1,
      sections: [
        { id: "section-1", name: "One", order: 0 },
        { id: "section-2", name: "Two", order: 1 },
      ],
      assignments,
    }),
  );

  try {
    const { result, unmount } = renderHook(() =>
      useChannelSections(pubkey, relayUrl),
    );

    act(() => result.current.assignChannel("chan-0000", "section-2"));
    act(() => result.current.assignChannel("chan-new", "section-1"));

    assert.equal(result.current.assignments["chan-0000"], "section-2");
    assert.equal(result.current.assignments["chan-new"], "section-1");
    assert.equal(result.current.assignments["chan-0001"], undefined);
    assert.equal(
      Object.keys(result.current.assignments).length,
      MAX_CHANNEL_SECTION_ASSIGNMENTS,
    );
    unmount();
  } finally {
    cleanup();
    relayClient.fetchEvents = originalFetchEvents;
    relayClient.subscribeLive = originalSubscribeLive;
    relayClient.subscribeToReconnects = originalSubscribeToReconnects;
  }
});

test("legacy subscription resolving after workspace cutover is disposed and cannot update canonical state", async () => {
  const { act, cleanup, renderHook } = await import("@testing-library/react");
  const { finalizeEvent } = await import("nostr-tools/pure");
  const { relayClient } = await import("@/shared/api/relayClient");
  const { useChannelSections } = await import("./useChannelSections.ts");

  const originalFetchEvents = relayClient.fetchEvents;
  const originalSubscribeLive = relayClient.subscribeLive;
  const originalSubscribeToReconnects = relayClient.subscribeToReconnects;
  const owner =
    "1111111111111111111111111111111111111111111111111111111111111111";
  const relaySelf =
    "1b84c5567b126440995d3ed5aaba0565d71e1834604819ff9c17f5e9d5dd078f";
  const ownerBytes = new Uint8Array(32).fill(1);
  const projection = {
    version: 1,
    owner_pubkey: owner,
    revision: 1,
    layout_revision: 1,
    key_epoch: 1,
    migration: {
      source_event_id:
        "2222222222222222222222222222222222222222222222222222222222222222",
      source_hash:
        "3333333333333333333333333333333333333333333333333333333333333333",
    },
    reader_key_envelope: "workspace-key-envelope",
    sections: [
      {
        id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        rank: 0,
        encrypted_label: "canonical-label",
        encrypted_icon: null,
      },
    ],
    assignments: [],
  };
  const projectionTemplate = {
    pubkey: owner,
    created_at: 1,
    kind: 30623,
    tags: [
      ["d", owner],
      ["p", owner],
    ],
    content: JSON.stringify(projection),
  };
  const projectionEvent = finalizeEvent(projectionTemplate, ownerBytes);
  const legacyStore = {
    version: 1,
    sections: [
      {
        id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        name: "legacy-name",
        order: 0,
      },
    ],
    assignments: {},
  };
  const legacyEvent = {
    id: "4444444444444444444444444444444444444444444444444444444444444444",
    pubkey: owner,
    created_at: 2,
    kind: 30078,
    tags: [["d", "channel-sections"]],
    content: "legacy-ciphertext",
    sig: "legacy-signature",
  };
  let resolveLegacySubscription;
  let legacyLiveCallback;
  let disposerCalls = 0;
  relayClient.fetchEvents = async (filter) =>
    filter.kinds.includes(30623) ? [projectionEvent] : [];
  relayClient.subscribeLive = (filter, onEvent) => {
    if (filter.kinds.includes(30078)) {
      legacyLiveCallback = onEvent;
      return new Promise((resolve) => {
        resolveLegacySubscription = resolve;
      });
    }
    return Promise.resolve(async () => {});
  };
  relayClient.subscribeToReconnects = () => () => {};
  const previousInternals = window.__TAURI_INTERNALS__;
  window.__TAURI_INTERNALS__ = {
    invoke: async (command, args) => {
      if (command === "get_relay_self") return relaySelf;
      if (command === "nip44_decrypt_from_self") {
        return args.ciphertext === "legacy-ciphertext"
          ? JSON.stringify(legacyStore)
          : "workspace-key";
      }
      if (command === "decrypt_workspace_metadata") return "canonical-name";
      throw new Error(`unexpected command ${command}`);
    },
  };

  try {
    const { result, unmount } = renderHook(() =>
      useChannelSections(owner, "wss://relay.example"),
    );
    const flush = async () => {
      for (let index = 0; index < 5; index += 1) {
        await new Promise((resolve) => setImmediate(resolve));
      }
    };
    await act(flush);
    assert.deepEqual(result.current.sections, [
      {
        id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        name: "canonical-name",
        order: 0,
      },
    ]);
    assert.equal(typeof resolveLegacySubscription, "function");
    assert.equal(typeof legacyLiveCallback, "function");

    resolveLegacySubscription(async () => {
      disposerCalls += 1;
    });
    await act(flush);
    assert.equal(disposerCalls, 1);

    legacyLiveCallback(legacyEvent);
    await act(flush);
    assert.deepEqual(result.current.sections, [
      {
        id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        name: "canonical-name",
        order: 0,
      },
    ]);
    unmount();
  } finally {
    cleanup();
    window.__TAURI_INTERNALS__ = previousInternals;
    relayClient.fetchEvents = originalFetchEvents;
    relayClient.subscribeLive = originalSubscribeLive;
    relayClient.subscribeToReconnects = originalSubscribeToReconnects;
  }
});

test("canonical cutover ignores storage/reconnect/live ingress and all legacy mutations", async () => {
  const { act, cleanup, renderHook } = await import("@testing-library/react");
  const { finalizeEvent } = await import("nostr-tools/pure");
  const { relayClient } = await import("@/shared/api/relayClient");
  const { storageKey } = await import("./channelSectionsStorage.ts");
  const { useChannelSections } = await import("./useChannelSections.ts");

  const originalFetchEvents = relayClient.fetchEvents;
  const originalSubscribeLive = relayClient.subscribeLive;
  const originalSubscribeToReconnects = relayClient.subscribeToReconnects;
  const owner =
    "1111111111111111111111111111111111111111111111111111111111111111";
  const relaySelf =
    "1b84c5567b126440995d3ed5aaba0565d71e1834604819ff9c17f5e9d5dd078f";
  const ownerBytes = new Uint8Array(32).fill(1);
  const projection = {
    version: 1,
    owner_pubkey: owner,
    revision: 4,
    layout_revision: 1,
    key_epoch: 2,
    migration: {
      source_event_id:
        "2222222222222222222222222222222222222222222222222222222222222222",
      source_hash:
        "3333333333333333333333333333333333333333333333333333333333333333",
    },
    reader_key_envelope: "workspace-key-envelope",
    sections: [
      {
        id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        rank: 0,
        encrypted_label: "ciphertext-alpha",
        encrypted_icon: null,
      },
      {
        id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        rank: 1,
        encrypted_label: "ciphertext-beta",
        encrypted_icon: "ciphertext-icon",
      },
    ],
    assignments: [
      {
        channel_id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
        section_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        revision: 1,
      },
    ],
  };
  const projectionEvent = finalizeEvent(
    {
      pubkey: owner,
      created_at: 1,
      kind: 30623,
      tags: [
        ["d", owner],
        ["p", owner],
      ],
      content: JSON.stringify(projection),
    },
    ownerBytes,
  );
  const legacyEvent = {
    id: "4444444444444444444444444444444444444444444444444444444444444444",
    pubkey: owner,
    created_at: 2,
    kind: 30078,
    tags: [["d", "channel-sections"]],
    content: "legacy-ciphertext",
    sig: "legacy-signature",
  };
  const legacyStore = {
    version: 1,
    sections: [{ id: "legacy", name: "Legacy", order: 0 }],
    assignments: {},
  };
  let legacyLiveCallback;
  let reconnectCallback;
  let legacyFetchCount = 0;
  let publishCount = 0;
  relayClient.fetchEvents = async (filter) => {
    if (filter.kinds.includes(30623)) return [projectionEvent];
    legacyFetchCount += 1;
    return [];
  };
  relayClient.subscribeLive = async (filter, onEvent) => {
    if (filter.kinds.includes(30078)) legacyLiveCallback = onEvent;
    return async () => {};
  };
  relayClient.publishEvent = async () => {
    publishCount += 1;
  };
  relayClient.subscribeToReconnects = (listener) => {
    reconnectCallback = listener;
    return () => {};
  };
  const previousInternals = window.__TAURI_INTERNALS__;
  window.__TAURI_INTERNALS__ = {
    invoke: async (command, args) => {
      if (command === "get_relay_self") return relaySelf;
      if (command === "nip44_decrypt_from_self") {
        return args.ciphertext === "legacy-ciphertext"
          ? JSON.stringify(legacyStore)
          : "workspace-key";
      }
      if (command === "decrypt_workspace_metadata") {
        if (args.envelope === "ciphertext-alpha") return "Alpha";
        if (args.envelope === "ciphertext-beta") return "Beta";
        if (args.envelope === "ciphertext-icon") return "folder";
      }
      throw new Error(`unexpected command ${command}`);
    },
  };

  try {
    const { result, unmount } = renderHook(() =>
      useChannelSections(owner, "wss://relay.example"),
    );
    const flush = async () => {
      for (let index = 0; index < 5; index += 1) {
        await new Promise((resolve) => setImmediate(resolve));
      }
    };
    await act(flush);
    const canonical = result.current.sections;
    const legacyKey = storageKey(owner, "wss://relay.example");
    const beforeStorage = window.localStorage.getItem(legacyKey);
    const beforeFetches = legacyFetchCount;

    window.dispatchEvent(
      new window.StorageEvent("storage", {
        key: legacyKey,
        newValue: JSON.stringify(legacyStore),
      }),
    );
    reconnectCallback();
    legacyLiveCallback(legacyEvent);
    await act(flush);
    assert.deepEqual(result.current.sections, canonical);
    assert.equal(window.localStorage.getItem(legacyKey), beforeStorage);
    assert.equal(legacyFetchCount, beforeFetches);
    assert.equal(publishCount, 0);

    const mutationResults = [
      result.current.createSection("blocked"),
      result.current.renameSection(
        "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        "blocked",
      ),
      result.current.deleteSection("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
      result.current.moveSectionUp("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"),
      result.current.moveSectionDown("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
      result.current.reorderSections([
        "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      ]),
      result.current.assignChannel(
        "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
        "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      ),
      result.current.unassignChannel("cccccccc-cccc-4ccc-8ccc-cccccccccccc"),
    ];
    assert.equal(mutationResults[0], null);
    await act(flush);
    assert.deepEqual(result.current.sections, canonical);
    assert.deepEqual(result.current.assignments, {
      "cccccccc-cccc-4ccc-8ccc-cccccccccccc":
        "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    });
    assert.equal(window.localStorage.getItem(legacyKey), beforeStorage);
    assert.equal(publishCount, 0);
    unmount();
  } finally {
    cleanup();
    window.__TAURI_INTERNALS__ = previousInternals;
    relayClient.fetchEvents = originalFetchEvents;
    relayClient.subscribeLive = originalSubscribeLive;
    relayClient.subscribeToReconnects = originalSubscribeToReconnects;
  }
});

test("legacy live, reconnect, and edit remain compatible before migration", async () => {
  const { act, cleanup, renderHook } = await import("@testing-library/react");
  const { relayClient } = await import("@/shared/api/relayClient");
  const { useChannelSections } = await import("./useChannelSections.ts");

  const originalFetchEvents = relayClient.fetchEvents;
  const originalSubscribeLive = relayClient.subscribeLive;
  const originalSubscribeToReconnects = relayClient.subscribeToReconnects;
  const owner = "legacy-compatible-owner";
  const relayUrl = "wss://relay.compatible";
  const liveEvent = {
    id: "1111111111111111111111111111111111111111111111111111111111111111",
    pubkey: owner,
    created_at: 1,
    kind: 30078,
    tags: [["d", "channel-sections"]],
    content: "legacy-live",
    sig: "signature",
  };
  const reconnectEvent = {
    ...liveEvent,
    id: "2222222222222222222222222222222222222222222222222222222222222222",
    created_at: 2,
    content: "legacy-reconnect",
  };
  const liveStore = {
    version: 1,
    sections: [{ id: "live", name: "Live", order: 0 }],
    assignments: {},
  };
  const reconnectStore = {
    version: 1,
    sections: [{ id: "reconnect", name: "Reconnect", order: 0 }],
    assignments: {},
  };
  let liveCallback;
  let reconnectCallback;
  let reconnectFetches = 0;
  relayClient.fetchEvents = async (filter) => {
    if (filter.kinds.includes(30078)) {
      reconnectFetches += 1;
      return reconnectFetches > 2 ? [reconnectEvent] : [];
    }
    return [];
  };
  relayClient.subscribeLive = async (filter, onEvent) => {
    if (filter.kinds.includes(30078)) liveCallback = onEvent;
    return async () => {};
  };
  relayClient.subscribeToReconnects = (listener) => {
    reconnectCallback = listener;
    return () => {};
  };
  const previousInternals = window.__TAURI_INTERNALS__;
  window.__TAURI_INTERNALS__ = {
    invoke: async (command, args) => {
      if (command === "nip44_decrypt_from_self") {
        if (args.ciphertext === "legacy-live") return JSON.stringify(liveStore);
        if (args.ciphertext === "legacy-reconnect") {
          return JSON.stringify(reconnectStore);
        }
      }
      throw new Error(`unexpected command ${command}`);
    },
  };
  try {
    const { result, unmount } = renderHook(() =>
      useChannelSections(owner, relayUrl),
    );
    const flush = async () => {
      for (let index = 0; index < 5; index += 1) {
        await new Promise((resolve) => setImmediate(resolve));
      }
    };
    await act(flush);
    assert.equal(result.current.sections.length, 0);
    liveCallback(liveEvent);
    await act(flush);
    assert.deepEqual(result.current.sections, [
      { id: "live", name: "Live", order: 0 },
    ]);
    reconnectCallback();
    await act(flush);
    assert.deepEqual(result.current.sections, [
      { id: "reconnect", name: "Reconnect", order: 0 },
    ]);
    act(() => result.current.renameSection("reconnect", "Edited"));
    assert.deepEqual(result.current.sections, [
      { id: "reconnect", name: "Edited", order: 0 },
    ]);
    unmount();
  } finally {
    cleanup();
    window.__TAURI_INTERNALS__ = previousInternals;
    relayClient.fetchEvents = originalFetchEvents;
    relayClient.subscribeLive = originalSubscribeLive;
    relayClient.subscribeToReconnects = originalSubscribeToReconnects;
  }
});

test("canonical cutover cancels a pending legacy publish", async () => {
  const { act, cleanup, renderHook } = await import("@testing-library/react");
  const { finalizeEvent } = await import("nostr-tools/pure");
  const { relayClient } = await import("@/shared/api/relayClient");
  const { useChannelSections } = await import("./useChannelSections.ts");

  const originalFetchEvents = relayClient.fetchEvents;
  const originalSubscribeLive = relayClient.subscribeLive;
  const originalSubscribeToReconnects = relayClient.subscribeToReconnects;
  const originalSetTimeout = window.setTimeout;
  const originalClearTimeout = window.clearTimeout;
  const owner =
    "3333333333333333333333333333333333333333333333333333333333333333";
  const relaySelf =
    "1b84c5567b126440995d3ed5aaba0565d71e1834604819ff9c17f5e9d5dd078f";
  const ownerBytes = new Uint8Array(32).fill(1);
  const projection = {
    version: 1,
    owner_pubkey: owner,
    revision: 1,
    layout_revision: 1,
    key_epoch: 1,
    migration: {
      source_event_id:
        "4444444444444444444444444444444444444444444444444444444444444444",
      source_hash:
        "5555555555555555555555555555555555555555555555555555555555555555",
    },
    reader_key_envelope: "workspace-key-envelope",
    sections: [
      {
        id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        rank: 0,
        encrypted_label: "canonical-label",
        encrypted_icon: null,
      },
    ],
    assignments: [],
  };
  const projectionEvent = finalizeEvent(
    {
      pubkey: owner,
      created_at: 1,
      kind: 30623,
      tags: [
        ["d", owner],
        ["p", owner],
      ],
      content: JSON.stringify(projection),
    },
    ownerBytes,
  );
  let workspaceCallback;
  let pendingTimer;
  let pendingTimerCleared = false;
  let publishCount = 0;
  relayClient.fetchEvents = async () => [];
  relayClient.subscribeLive = async (filter, onEvent) => {
    if (filter.kinds.includes(30623)) workspaceCallback = onEvent;
    return async () => {};
  };
  relayClient.subscribeToReconnects = () => () => {};
  relayClient.publishEvent = async () => {
    publishCount += 1;
  };
  window.setTimeout = (callback, delay) => {
    if (delay === 2000) {
      pendingTimer = callback;
      return 42;
    }
    return originalSetTimeout(callback, delay);
  };
  window.clearTimeout = (timer) => {
    if (timer === 42) pendingTimerCleared = true;
    else originalClearTimeout(timer);
  };
  const previousInternals = window.__TAURI_INTERNALS__;
  window.__TAURI_INTERNALS__ = {
    invoke: async (command) => {
      if (command === "get_relay_self") return relaySelf;
      if (command === "nip44_decrypt_from_self") return "workspace-key";
      if (command === "decrypt_workspace_metadata") return "canonical-name";
      throw new Error(`unexpected command ${command}`);
    },
  };
  try {
    const { result, unmount } = renderHook(() =>
      useChannelSections(owner, "wss://relay.pending"),
    );
    const flush = async () => {
      for (let index = 0; index < 5; index += 1) {
        await new Promise((resolve) => setImmediate(resolve));
      }
    };
    await act(flush);
    act(() => result.current.createSection("pending"));
    assert.equal(typeof pendingTimer, "function");
    workspaceCallback(projectionEvent);
    await act(flush);
    assert.equal(pendingTimerCleared, true);
    assert.equal(publishCount, 0);
    unmount();
  } finally {
    cleanup();
    window.setTimeout = originalSetTimeout;
    window.clearTimeout = originalClearTimeout;
    window.__TAURI_INTERNALS__ = previousInternals;
    relayClient.fetchEvents = originalFetchEvents;
    relayClient.subscribeLive = originalSubscribeLive;
    relayClient.subscribeToReconnects = originalSubscribeToReconnects;
  }
});
