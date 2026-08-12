import * as React from "react";

import type { InboxItem } from "@/features/home/lib/inbox";
import {
  handoffInboxLoadingDraft,
  INBOX_LOADING_DRAFT_KEY,
  loadDraftEntry,
  useDraftsSnapshot,
} from "@/features/messages/lib/useDrafts";

type InboxLoadingDraftHandoffOptions = {
  feedReady: boolean;
  hasVisibleItems: boolean;
  isMessagesMode: boolean;
  isNarrowViewport: boolean;
  selectedItem: InboxItem | null;
};

/** Moves the provisional loading draft once desktop Inbox resolves a target. */
export function useInboxLoadingDraftHandoff({
  feedReady,
  hasVisibleItems,
  isMessagesMode,
  isNarrowViewport,
  selectedItem,
}: InboxLoadingDraftHandoffOptions): boolean {
  useDraftsSnapshot();
  const provisionalDraft = loadDraftEntry(INBOX_LOADING_DRAFT_KEY);
  const channelId = selectedItem?.item.channelId ?? null;
  const destinationKey = selectedItem
    ? selectedItem.item.channelType === "dm"
      ? (channelId ?? selectedItem.conversationId)
      : `thread:${selectedItem.conversationId}`
    : null;

  React.useEffect(() => {
    if (!feedReady || !provisionalDraft || !channelId || !destinationKey) {
      return;
    }
    handoffInboxLoadingDraft(destinationKey, channelId);
  }, [channelId, destinationKey, feedReady, provisionalDraft]);

  return Boolean(
    feedReady &&
      provisionalDraft &&
      isMessagesMode &&
      (selectedItem || (!isNarrowViewport && hasVisibleItems)),
  );
}
