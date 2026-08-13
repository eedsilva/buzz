import { expect, test } from "@playwright/test";

import { waitForAnimations } from "../helpers/animations";
import { installMockBridge, TEST_IDENTITIES } from "../helpers/bridge";
import { KIND_HUDDLE_STARTED } from "../../src/shared/constants/kinds";

const SHOTS = "test-results/message-feedback";

async function waitForMockLiveSubscription(
  page: import("@playwright/test").Page,
  channelName: string,
) {
  await expect
    .poll(async () => {
      return page.evaluate(
        ({ ch }) =>
          (
            window as Window & {
              __BUZZ_E2E_HAS_MOCK_LIVE_SUBSCRIPTION__?: (input: {
                channelName: string;
              }) => boolean;
            }
          ).__BUZZ_E2E_HAS_MOCK_LIVE_SUBSCRIPTION__?.({ channelName: ch }) ??
          false,
        { ch: channelName },
      );
    })
    .toBe(true);
}

async function seedMessageBubbles(page: import("@playwright/test").Page) {
  await page.addInitScript(() => {
    window.localStorage.setItem("buzz.appearance.messageStyle", "bubbles");
  });
}

test("pending continuation keeps Sending next to its timestamp", async ({
  page,
}) => {
  await installMockBridge(page);
  await page.goto("/");
  await page.getByTestId("channel-general").click();
  await expect(page.getByTestId("chat-title")).toHaveText("general");
  await waitForMockLiveSubscription(page, "general");

  const sentMessage = `Message before pending state ${Date.now()}`;
  const pendingMessage = `Pending message status ${Date.now()}`;
  const createdAt = Math.floor(Date.now() / 1_000);
  await page.evaluate(
    ({ firstMessage, secondMessage, timestamp }) => {
      const emit = (
        window as Window & {
          __BUZZ_E2E_EMIT_MOCK_MESSAGE__?: (input: {
            channelName: string;
            content: string;
            createdAt: number;
            pending?: boolean;
          }) => unknown;
        }
      ).__BUZZ_E2E_EMIT_MOCK_MESSAGE__;
      emit?.({
        channelName: "general",
        content: firstMessage,
        createdAt: timestamp - 1,
      });
      emit?.({
        channelName: "general",
        content: secondMessage,
        createdAt: timestamp,
        pending: true,
      });
    },
    {
      firstMessage: sentMessage,
      secondMessage: pendingMessage,
      timestamp: createdAt,
    },
  );

  const pendingRow = page
    .getByTestId("message-row")
    .filter({ hasText: pendingMessage });
  const status = pendingRow.getByTestId("message-send-status");
  await expect(status).toHaveText("Sending…");
  await expect(pendingRow.getByTestId("message-author")).toHaveCount(1);

  const timestamp = status.locator("xpath=../p[1]");
  const [timestampBox, statusBox] = await Promise.all([
    timestamp.boundingBox(),
    status.boundingBox(),
  ]);
  expect(timestampBox).not.toBeNull();
  expect(statusBox).not.toBeNull();
  if (!timestampBox || !statusBox) {
    throw new Error("Pending message metadata is missing its inline layout.");
  }
  expect(statusBox.x).toBeGreaterThan(timestampBox.x);
  expect(Math.abs(statusBox.y - timestampBox.y)).toBeLessThanOrEqual(1);

  await waitForAnimations(page);
  await pendingRow.screenshot({ path: `${SHOTS}/pending-message-inline.png` });
});

test("profile hover uses the channel hover surface", async ({ page }) => {
  await installMockBridge(page);
  await page.goto("/");

  const profile = page.getByTestId("sidebar-profile-card");
  const channel = page.getByTestId("channel-random");
  await channel.hover();
  const channelHoverColor = await channel.evaluate(
    (element) => getComputedStyle(element).backgroundColor,
  );
  await profile.hover();
  await expect(profile).toHaveCSS("background-color", channelHoverColor);

  await waitForAnimations(page);
  await page
    .getByTestId("app-sidebar")
    .screenshot({ path: `${SHOTS}/profile-hover.png` });
});

test("open messages use the compact ellipsis actions menu", async ({
  page,
}) => {
  await page.addInitScript(() => {
    window.localStorage.setItem(
      "buzz.quick-reaction-emojis.v1:e2e-default-community",
      JSON.stringify([{ count: 2, emoji: "🔥", lastUsedAt: Date.now() }]),
    );
  });
  await installMockBridge(page);
  await page.goto("/");
  await page.getByTestId("channel-general").click();
  await expect(page.getByTestId("chat-title")).toHaveText("general");

  const row = page
    .getByTestId("message-row")
    .filter({ hasText: "React to me with a custom emoji" })
    .last();
  await expect(row).toBeVisible();
  await row.hover();

  const actionBar = row.locator('[data-testid^="message-action-bar-"]');
  await expect(actionBar).toHaveAttribute("data-presentation", "menu");
  await expect(
    actionBar.getByRole("button", { name: "More actions" }),
  ).toBeVisible();
  await expect(
    actionBar.getByRole("button", { name: "Open reactions" }),
  ).toHaveCount(0);
  await expect(actionBar.getByRole("button", { name: "Reply" })).toHaveCount(0);

  const [rowBox, actionBarBox] = await Promise.all([
    row.boundingBox(),
    actionBar.boundingBox(),
  ]);
  if (!rowBox || !actionBarBox) {
    throw new Error("Expected open message action geometry.");
  }
  expect(actionBarBox.y).toBeGreaterThanOrEqual(rowBox.y);
  expect(actionBarBox.x + actionBarBox.width).toBeLessThanOrEqual(
    rowBox.x + rowBox.width + 1,
  );

  await actionBar.getByRole("button", { name: "More actions" }).click();
  await expect(page.getByRole("menu")).toBeVisible();
  const quickReactions = page.locator(
    '[data-testid^="message-quick-reactions-"]',
  );
  await expect(quickReactions).toBeVisible();
  await expect(
    quickReactions.getByRole("button", { name: /^React with / }),
  ).toHaveCount(5);
  await expect(
    page.getByRole("menuitem", { name: "Reply", exact: true }),
  ).toBeVisible();

  await waitForAnimations(page);
  await page.screenshot({ path: `${SHOTS}/open-message-actions.png` });
});

test("left-aligned continuation bubbles join on the left edge", async ({
  page,
}) => {
  await seedMessageBubbles(page);
  await installMockBridge(page);
  await page.goto("/");
  await page.getByTestId("channel-general").click();
  await expect(page.getByTestId("chat-title")).toHaveText("general");
  await waitForMockLiveSubscription(page, "general");

  const suffix = Date.now();
  const messages = {
    before: `Different author before ${suffix}`,
    first: `First grouped bubble for @bob ${suffix}`,
    middle: `Middle grouped bubble ${suffix}`,
    last: `Last grouped bubble ${suffix}`,
    isolated: `Isolated bubble ${suffix}`,
  };
  const createdAt = Math.floor(Date.now() / 1_000);
  await page.evaluate(
    ({ alicePubkey, bobPubkey, content, timestamp }) => {
      const emit = (
        window as Window & {
          __BUZZ_E2E_EMIT_MOCK_MESSAGE__?: (input: {
            channelName: string;
            content: string;
            createdAt: number;
            extraTags?: string[][];
            pubkey: string;
          }) => unknown;
        }
      ).__BUZZ_E2E_EMIT_MOCK_MESSAGE__;
      [
        { content: content.before, extraTags: [], pubkey: bobPubkey },
        {
          content: content.first,
          extraTags: [["p", bobPubkey]],
          pubkey: alicePubkey,
        },
        { content: content.middle, extraTags: [], pubkey: alicePubkey },
        { content: content.last, extraTags: [], pubkey: alicePubkey },
        { content: content.isolated, extraTags: [], pubkey: bobPubkey },
      ].forEach((message, index) => {
        emit?.({
          channelName: "general",
          content: message.content,
          createdAt: timestamp + index,
          extraTags: message.extraTags,
          pubkey: message.pubkey,
        });
      });
    },
    {
      alicePubkey: TEST_IDENTITIES.alice.pubkey,
      bobPubkey: TEST_IDENTITIES.bob.pubkey,
      content: messages,
      timestamp: createdAt,
    },
  );

  const rowFor = (content: string) =>
    page.getByTestId("message-row").filter({ hasText: content });
  const firstRow = rowFor(messages.first);
  const middleRow = rowFor(messages.middle);
  const isolatedRow = rowFor(messages.isolated);
  await expect(isolatedRow).toBeVisible();

  const radii = async (content: string) =>
    rowFor(content)
      .getByTestId("message-body-surface")
      .evaluate((bubble) => {
        const style = getComputedStyle(bubble);
        return {
          bottomLeft: Number.parseFloat(style.borderBottomLeftRadius),
          bottomRight: Number.parseFloat(style.borderBottomRightRadius),
          topLeft: Number.parseFloat(style.borderTopLeftRadius),
          topRight: Number.parseFloat(style.borderTopRightRadius),
        };
      });

  const [first, middle, last, isolated] = await Promise.all([
    radii(messages.first),
    radii(messages.middle),
    radii(messages.last),
    radii(messages.isolated),
  ]);
  expect(first.topLeft).toBe(first.topRight);
  expect(first.bottomLeft).toBeLessThan(first.bottomRight);
  expect(middle.topLeft).toBeLessThan(middle.topRight);
  expect(middle.bottomLeft).toBeLessThan(middle.bottomRight);
  expect(last.topLeft).toBeLessThan(last.topRight);
  expect(last.bottomLeft).toBe(last.bottomRight);
  expect(new Set(Object.values(isolated)).size).toBe(1);

  const isolatedPadding = await isolatedRow
    .getByTestId("message-body-surface")
    .evaluate((bubble) => {
      const style = getComputedStyle(bubble);
      return {
        bottom: Number.parseFloat(style.paddingBottom),
        left: Number.parseFloat(style.paddingLeft),
        right: Number.parseFloat(style.paddingRight),
        top: Number.parseFloat(style.paddingTop),
      };
    });
  expect(isolatedPadding.left).toBeGreaterThan(12);
  expect(isolatedPadding.top).toBeGreaterThan(8);
  expect(isolatedPadding.right).toBe(isolatedPadding.left);
  expect(isolatedPadding.bottom).toBe(isolatedPadding.top);

  const mentionStyle = await firstRow
    .locator("[data-mention]")
    .evaluate((mention) => {
      const style = getComputedStyle(mention);
      return {
        backgroundColor: style.backgroundColor,
        fontWeight: Number(style.fontWeight),
        paddingLeft: Number.parseFloat(style.paddingLeft),
        paddingRight: Number.parseFloat(style.paddingRight),
      };
    });
  expect(mentionStyle.backgroundColor).toBe("rgba(0, 0, 0, 0)");
  expect(mentionStyle.fontWeight).toBeGreaterThanOrEqual(600);
  expect(mentionStyle.paddingLeft).toBe(0);
  expect(mentionStyle.paddingRight).toBe(0);

  await middleRow.hover();
  const actionBar = middleRow.locator('[data-testid^="message-action-bar-"]');
  await expect(actionBar).toBeVisible();
  await expect(actionBar).toHaveAttribute("data-presentation", "menu");
  const [hoverBubble, actionBarBox, rootFontSize] = await Promise.all([
    middleRow.getByTestId("message-body-surface").boundingBox(),
    actionBar.boundingBox(),
    page.evaluate(() =>
      Number.parseFloat(getComputedStyle(document.documentElement).fontSize),
    ),
  ]);
  if (!hoverBubble || !actionBarBox) {
    throw new Error("Expected bubble and top-right action geometry.");
  }
  expect(
    Math.abs(
      actionBarBox.x +
        actionBarBox.width -
        hoverBubble.x -
        hoverBubble.width -
        rootFontSize * 0.5,
    ),
  ).toBeLessThanOrEqual(1);
  expect(
    Math.abs(actionBarBox.y - hoverBubble.y + rootFontSize * 0.5),
  ).toBeLessThanOrEqual(1);

  await middleRow.getByRole("button", { name: "More actions" }).click();
  await expect(page.getByRole("menu")).toBeVisible();
  const combinedTray = page.locator(
    '[data-testid^="message-quick-reactions-"]',
  );
  await expect(combinedTray).toBeVisible();
  await waitForAnimations(page);
  await page.screenshot({ path: `${SHOTS}/combined-message-actions.png` });
  await combinedTray.getByRole("button", { name: "Open reactions" }).click();
  await expect(page.locator("em-emoji-picker")).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(page.locator("em-emoji-picker")).toHaveCount(0);
  await expect(page.getByRole("menu")).toBeVisible();
  await combinedTray.getByRole("button", { name: "React with :+1:" }).click();
  const reactionBar = middleRow.getByTestId("message-reactions");
  await expect(reactionBar).toBeVisible();
  await expect
    .poll(async () => {
      const [bubble, reactions, firstPill] = await Promise.all([
        middleRow.getByTestId("message-body-surface").boundingBox(),
        reactionBar.boundingBox(),
        reactionBar.getByRole("button").first().boundingBox(),
      ]);
      if (!bubble || !reactions || !firstPill) return false;
      return (
        reactions.y < bubble.y + bubble.height &&
        Math.abs(firstPill.x - bubble.x - 12) <= 1
      );
    })
    .toBe(true);
  const reactionPillStyle = await reactionBar
    .getByRole("button")
    .first()
    .evaluate((pill) => {
      const style = getComputedStyle(pill);
      return {
        backgroundColor: style.backgroundColor,
        color: style.color,
        opacity: Number(style.opacity),
      };
    });
  expect(reactionPillStyle.opacity).toBe(1);
  expect(reactionPillStyle.backgroundColor).not.toBe("rgba(0, 0, 0, 0)");
  expect(reactionPillStyle.color).not.toContain("/");

  await page.waitForTimeout(1_200);
  await page.mouse.move(0, 0);
  await waitForAnimations(page);
  const [top, bottom] = await Promise.all([
    firstRow.boundingBox(),
    isolatedRow.boundingBox(),
  ]);
  if (!top || !bottom) throw new Error("Expected grouped bubble geometry.");
  await page.screenshot({
    path: `${SHOTS}/left-aligned-continuation-bubbles.png`,
    clip: {
      x: Math.max(0, top.x - 12),
      y: Math.max(0, top.y - 12),
      width: Math.min(720, page.viewportSize()?.width ?? 720),
      height: bottom.y + bottom.height - top.y + 24,
    },
  });
});

test("direct messages use the same grouped message bubbles", async ({
  page,
}) => {
  await seedMessageBubbles(page);
  await installMockBridge(page);
  await page.goto("/");
  await page.getByTestId("channel-alice-tyler").click();
  await expect(page.getByTestId("chat-title")).toHaveText("alice-tyler");
  await waitForMockLiveSubscription(page, "alice-tyler");

  const suffix = Date.now();
  const first = `DM grouped bubble one ${suffix}`;
  const second = `DM grouped bubble two ${suffix}`;
  await page.evaluate(
    ({ alicePubkey, firstContent, secondContent, timestamp, tylerPubkey }) => {
      const emit = window.__BUZZ_E2E_EMIT_MOCK_MESSAGE__;
      emit?.({
        channelName: "alice-tyler",
        content: `DM group barrier ${timestamp}`,
        createdAt: timestamp,
        pubkey: tylerPubkey,
      });
      emit?.({
        channelName: "alice-tyler",
        content: firstContent,
        createdAt: timestamp + 1,
        pubkey: alicePubkey,
      });
      emit?.({
        channelName: "alice-tyler",
        content: secondContent,
        createdAt: timestamp + 2,
        pubkey: alicePubkey,
      });
    },
    {
      alicePubkey: TEST_IDENTITIES.alice.pubkey,
      firstContent: first,
      secondContent: second,
      timestamp: Math.floor(Date.now() / 1_000),
      tylerPubkey: TEST_IDENTITIES.tyler.pubkey,
    },
  );

  const rowFor = (content: string) =>
    page.getByTestId("message-row").filter({ hasText: content });
  const firstBubble = rowFor(first).getByTestId("message-body-surface");
  const secondBubble = rowFor(second).getByTestId("message-body-surface");
  await expect(secondBubble).toBeVisible();
  const [firstRadii, secondRadii] = await Promise.all([
    firstBubble.evaluate((bubble) => {
      const style = getComputedStyle(bubble);
      return {
        bottomLeft: Number.parseFloat(style.borderBottomLeftRadius),
        bottomRight: Number.parseFloat(style.borderBottomRightRadius),
      };
    }),
    secondBubble.evaluate((bubble) => {
      const style = getComputedStyle(bubble);
      return {
        topLeft: Number.parseFloat(style.borderTopLeftRadius),
        topRight: Number.parseFloat(style.borderTopRightRadius),
      };
    }),
  ]);
  expect(firstRadii.bottomLeft).toBeLessThan(firstRadii.bottomRight);
  expect(secondRadii.topLeft).toBeLessThan(secondRadii.topRight);

  await waitForAnimations(page);
  await page.screenshot({ path: `${SHOTS}/direct-message-bubbles.png` });
});

test("standalone huddle cards do not get a second message container", async ({
  page,
}) => {
  await seedMessageBubbles(page);
  await installMockBridge(page);
  await page.goto("/");
  await page.getByTestId("channel-general").click();
  await expect(page.getByTestId("chat-title")).toHaveText("general");
  await waitForMockLiveSubscription(page, "general");

  await page.evaluate((kind) => {
    window.__BUZZ_E2E_EMIT_MOCK_MESSAGE__?.({
      channelName: "general",
      content: JSON.stringify({
        ephemeral_channel_id: "10000000-0000-4000-8000-000000000009",
      }),
      createdAt: Math.floor(Date.now() / 1_000),
      id: "f".repeat(64),
      kind,
    });
  }, KIND_HUDDLE_STARTED);

  const attachment = page.getByTestId("huddle-attachment");
  const row = attachment.locator(
    "xpath=ancestor::*[@data-testid='message-row']",
  );
  await expect(attachment).toBeVisible();
  await expect(row.getByTestId("message-body-surface")).toHaveCount(0);
  await expect(
    row.getByTestId("message-standalone-card-content"),
  ).toBeVisible();

  await waitForAnimations(page);
  await row.screenshot({ path: `${SHOTS}/standalone-huddle-card.png` });
});
