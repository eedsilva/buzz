import * as React from "react";

import { useKnownAgentPubkeys } from "@/features/agents/useKnownAgentPubkeys";
import type { InboxContextMessage } from "@/features/home/lib/inbox";
import { toTimelineMessage } from "@/features/home/lib/inboxViewHelpers";
import { formatTimeWithoutDayPeriod } from "@/features/messages/lib/dateFormatters";
import type { TimelineMessage } from "@/features/messages/types";
import { getConfigNudgeAuthorPubkey } from "@/features/messages/ui/configNudgeAuthPubkey";
import { MessageActionBar } from "@/features/messages/ui/MessageActionBar";
import { MessageAgentOwner } from "@/features/messages/ui/MessageAgentOwner";
import {
  MessageAuthorText,
  MessageHeaderRow,
} from "@/features/messages/ui/MessageHeader";
import { MessageReactions } from "@/features/messages/ui/MessageReactions";
import {
  getMessageBubbleBottomPaddingClass,
  getMessageBubbleLayout,
  MESSAGE_BUBBLE_CONTENT_PADDING_CLASSES,
} from "@/features/messages/ui/messageBubbleLayout";
import { UnreadDivider } from "@/features/messages/ui/UnreadDivider";
import { useReactionHandler } from "@/features/messages/ui/useReactionHandler";
import { useMessageEmoji } from "@/features/messages/lib/useMessageEmoji";
import { UserProfilePopover } from "@/features/profile/ui/UserProfilePopover";
import { cn } from "@/shared/lib/cn";
import { useMessageStyle } from "@/shared/lib/messageStylePreference";
import { normalizePubkey } from "@/shared/lib/pubkey";
import { Markdown } from "@/shared/ui/markdown";
import { hasLinkPreviewSuppression } from "@/features/messages/lib/formatTimelineMessages";
import { UserAvatar } from "@/shared/ui/UserAvatar";

export type InboxDisplayMessage = InboxContextMessage & {
  depth: number;
};

type InboxMessageRowProps = {
  agentPubkeys?: ReadonlySet<string>;
  canReply: boolean;
  /** Channel UUID for "Copy link" — passed straight through to MessageActionBar. */
  channelId?: string | null;
  isContinuation?: boolean;
  isFollowedByContinuation?: boolean;
  isFirst?: boolean;
  isFocusHighlightVisible: boolean;
  message: InboxDisplayMessage;
  onEdit?: (message: InboxDisplayMessage) => void;
  onSelectReplyTarget: (message: InboxDisplayMessage) => void;
  onToggleReaction?: (
    message: TimelineMessage,
    emoji: string,
    remove: boolean,
  ) => Promise<void>;
  showUnreadBoundary?: boolean;
};

export function InboxMessageRow({
  agentPubkeys,
  canReply,
  channelId = null,
  isContinuation = false,
  isFollowedByContinuation = false,
  isFirst = false,
  isFocusHighlightVisible,
  message,
  onEdit,
  onSelectReplyTarget,
  onToggleReaction,
  showUnreadBoundary = false,
}: InboxMessageRowProps) {
  const showMessageBubbles = useMessageStyle() === "bubbles";
  const timelineMessage = React.useMemo(
    () => toTimelineMessage(message),
    [message],
  );
  const { customEmoji, emojiOnly } = useMessageEmoji(
    message.content,
    message.tags,
  );
  const [badgeBurstEmoji, setBadgeBurstEmoji] = React.useState<string | null>(
    null,
  );
  const {
    reactions,
    canToggle: canToggleReactions,
    pending: reactionPending,
    errorMessage: reactionErrorMessage,
    select: handleReactionSelect,
  } = useReactionHandler(timelineMessage, onToggleReaction);
  // "Is this pubkey an agent" = the community-scoped baseline every surface
  // shares plus this surface's extras passed via `agentPubkeys` (HomeView
  // folds feed-profile `isAgent` flags in). Mirrors MessageRow's predicate.
  const knownAgentPubkeys = useKnownAgentPubkeys();
  const isKnownAgentPubkey = React.useCallback(
    (pubkey: string) => {
      const normalized = normalizePubkey(pubkey);
      return (
        knownAgentPubkeys.has(normalized) ||
        agentPubkeys?.has(normalized) === true
      );
    },
    [agentPubkeys, knownAgentPubkeys],
  );
  const isAuthorAgent = isKnownAgentPubkey(message.authorPubkey);
  const profileRole = isAuthorAgent ? "bot" : undefined;
  const hoverTimestampLabel = formatTimeWithoutDayPeriod(
    message.timeLabel ?? message.fullTimestampLabel,
  );
  const { radiusClass, rowSpacingClass } = getMessageBubbleLayout(
    isContinuation,
    isFollowedByContinuation,
  );
  const actionBarNode =
    canReply || canToggleReactions || onEdit ? (
      <div
        className={cn(
          "absolute top-1 z-10",
          showMessageBubbles ? "right-0" : "right-2",
          showMessageBubbles
            ? isFirst
              ? "sm:top-3"
              : "sm:top-2 sm:-translate-y-1/2"
            : !isFirst && "sm:top-0 sm:-translate-y-1/2",
        )}
      >
        <MessageActionBar
          channelId={channelId}
          message={timelineMessage}
          onEdit={onEdit ? () => onEdit(message) : undefined}
          onReactionSelect={
            canToggleReactions ? handleReactionSelect : undefined
          }
          onReactionBadgeBurstRequest={
            reactionPending ? undefined : setBadgeBurstEmoji
          }
          onReply={canReply ? () => onSelectReplyTarget(message) : undefined}
          reactionErrorMessage={reactionErrorMessage}
          reactions={reactions}
          presentation="menu"
        />
      </div>
    ) : null;

  return (
    <div
      className={cn(
        "relative px-2",
        showMessageBubbles && (isFollowedByContinuation ? "pb-0" : "pb-2.5"),
      )}
    >
      {showUnreadBoundary ? <UnreadDivider /> : null}
      {message.isSelected ? (
        <div
          aria-hidden="true"
          className={cn(
            "pointer-events-none absolute inset-x-3 inset-y-1 rounded-2xl transition-opacity duration-1000",
            isFocusHighlightVisible
              ? "bg-primary/[0.07] opacity-100"
              : "bg-primary/[0.07] opacity-0",
          )}
        />
      ) : null}
      <article
        className={cn(
          "group/message relative z-10 mx-1 flex gap-2.5 rounded-2xl px-2 transition-colors",
          showMessageBubbles
            ? rowSpacingClass
            : "py-conversation-row hover:bg-muted/50 focus-within:bg-muted/50",
          isContinuation ? "items-center" : "items-start",
        )}
        data-message-id={message.id}
        data-testid={
          message.isSelected
            ? "home-inbox-selected-message"
            : "home-inbox-context-message"
        }
      >
        {showMessageBubbles ? null : actionBarNode}

        {isContinuation ? (
          <div
            aria-hidden="true"
            className="flex w-9 shrink-0 self-stretch items-start justify-end pt-0.5"
            title={message.fullTimestampLabel}
          >
            <p
              className="shrink-0 cursor-default whitespace-nowrap text-message-timestamp font-normal tabular-nums text-muted-foreground/55 opacity-0 transition-opacity group-hover/message:opacity-100 group-focus-within/message:opacity-100"
              data-testid="inbox-message-timestamp"
            >
              {hoverTimestampLabel}
            </p>
          </div>
        ) : (
          <div className="relative shrink-0">
            <UserProfilePopover
              botIdenticonValue={message.authorLabel}
              pubkey={message.authorPubkey}
              role={profileRole}
              triggerElement="span"
            >
              <span className="inline-flex shrink-0 rounded-full focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-ring">
                <UserAvatar
                  avatarUrl={message.avatarUrl}
                  className="h-9 w-9 shrink-0"
                  displayName={message.authorLabel}
                  size="md"
                />
              </span>
            </UserProfilePopover>
          </div>
        )}

        <div className="flex min-w-0 flex-1 flex-col gap-0.5">
          {isContinuation ? null : (
            <MessageHeaderRow className="gap-x-2">
              <UserProfilePopover
                botIdenticonValue={message.authorLabel}
                pubkey={message.authorPubkey}
                role={profileRole}
                triggerElement="span"
              >
                <MessageAuthorText className="block max-w-full">
                  {message.authorLabel}
                </MessageAuthorText>
              </UserProfilePopover>
              {message.isAgent ? (
                <MessageAgentOwner
                  ownerLabel={message.ownerLabel}
                  ownerPubkey={message.ownerPubkey}
                />
              ) : null}
              <p
                className="shrink-0 text-message-timestamp font-normal tabular-nums text-muted-foreground/55"
                data-testid="inbox-message-timestamp"
              >
                {message.fullTimestampLabel}
              </p>
            </MessageHeaderRow>
          )}

          <div
            className={cn(
              isContinuation ? "mt-0" : "mt-conversation-body",
              showMessageBubbles && "w-fit max-w-full",
            )}
          >
            {showMessageBubbles ? (
              <div
                className={cn(
                  "relative w-fit max-w-full bg-muted/50",
                  MESSAGE_BUBBLE_CONTENT_PADDING_CLASSES,
                  radiusClass,
                  getMessageBubbleBottomPaddingClass(reactions.length > 0),
                )}
                data-testid="message-body-surface"
              >
                {actionBarNode}
                <Markdown
                  className={cn(
                    "message-bubble-markdown max-w-full text-left text-message text-foreground",
                    emojiOnly &&
                      "text-4xl leading-tight [&_p]:leading-tight [&_img[data-custom-emoji]]:h-[1.45em] [&_img[data-custom-emoji]]:align-middle [&_button:has(img[data-custom-emoji])]:align-middle",
                  )}
                  configNudgeAuthorPubkey={getConfigNudgeAuthorPubkey(
                    timelineMessage,
                    isKnownAgentPubkey,
                  )}
                  content={message.content}
                  messageId={message.id}
                  linkPreviewsSuppressed={hasLinkPreviewSuppression(
                    timelineMessage.tags,
                  )}
                  customEmoji={customEmoji}
                  mentionNames={message.mentionNames}
                  mentionPubkeysByName={message.mentionPubkeysByName}
                />
              </div>
            ) : (
              <Markdown
                className={cn(
                  "max-w-full text-left text-message text-foreground",
                  emojiOnly &&
                    "text-4xl leading-tight [&_p]:leading-tight [&_img[data-custom-emoji]]:h-[1.45em] [&_img[data-custom-emoji]]:align-middle [&_button:has(img[data-custom-emoji])]:align-middle",
                )}
                configNudgeAuthorPubkey={getConfigNudgeAuthorPubkey(
                  timelineMessage,
                  isKnownAgentPubkey,
                )}
                content={message.content}
                messageId={message.id}
                linkPreviewsSuppressed={hasLinkPreviewSuppression(
                  timelineMessage.tags,
                )}
                customEmoji={customEmoji}
                mentionNames={message.mentionNames}
                mentionPubkeysByName={message.mentionPubkeysByName}
              />
            )}
            <MessageReactions
              canToggle={canToggleReactions}
              messageId={message.id}
              onSelect={(emoji) => {
                void handleReactionSelect(emoji);
              }}
              burstEmojiOnRender={badgeBurstEmoji}
              onBurstEmojiRendered={(emoji) => {
                setBadgeBurstEmoji((current) =>
                  current === emoji ? null : current,
                );
              }}
              pending={reactionPending}
              placement={showMessageBubbles ? "bubble-overlap" : "inline"}
              reactions={reactions}
            />
            {reactionErrorMessage ? (
              <p className="mt-1.5 text-xs text-destructive">
                {reactionErrorMessage}
              </p>
            ) : null}
          </div>
        </div>
      </article>
    </div>
  );
}
