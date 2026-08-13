import type {
  TimelineMessage,
  TimelineReaction,
} from "@/features/messages/types";
import { cn } from "@/shared/lib/cn";
import { MessageActionBar } from "./MessageActionBar";

type MessageRowActionsProps = {
  anchorToBubble: boolean;
  channelId?: string | null;
  isFollowingThread?: boolean;
  isUnread?: boolean;
  message: TimelineMessage;
  onDelete?: (message: TimelineMessage) => void;
  onEdit?: (message: TimelineMessage) => void;
  onFollowThread?: (message: TimelineMessage) => void;
  onMarkRead?: (message: TimelineMessage) => void;
  onMarkUnread?: (message: TimelineMessage) => void;
  onReactionBadgeBurstRequest?: (emoji: string) => void;
  onReactionSelect?: (emoji: string) => Promise<void>;
  onRemindLater?: (message: TimelineMessage) => void;
  onReply?: (message: TimelineMessage) => void;
  onSendToChannel?: (message: TimelineMessage) => Promise<void>;
  onUnfollowThread?: (message: TimelineMessage) => void;
  reactionErrorMessage?: string | null;
  reactions: TimelineReaction[];
  showMessageBubbles: boolean;
};

export function MessageRowActions({
  anchorToBubble,
  channelId,
  isFollowingThread,
  isUnread,
  message,
  onDelete,
  onEdit,
  onFollowThread,
  onMarkRead,
  onMarkUnread,
  onReactionBadgeBurstRequest,
  onReactionSelect,
  onRemindLater,
  onReply,
  onSendToChannel,
  onUnfollowThread,
  reactionErrorMessage,
  reactions,
  showMessageBubbles,
}: MessageRowActionsProps) {
  return (
    <div
      className={cn(
        "absolute z-10",
        showMessageBubbles
          ? anchorToBubble
            ? "-right-2 -top-2"
            : "right-1 top-1"
          : "right-1 top-1",
      )}
    >
      <MessageActionBar
        channelId={channelId}
        isFollowingThread={isFollowingThread}
        isUnread={isUnread}
        message={message}
        onDelete={onDelete}
        onEdit={onEdit}
        onFollowThread={onFollowThread}
        onMarkRead={onMarkRead}
        onMarkUnread={onMarkUnread}
        onReactionBadgeBurstRequest={onReactionBadgeBurstRequest}
        onReactionSelect={onReactionSelect}
        onRemindLater={onRemindLater}
        onReply={onReply}
        onSendToChannel={onSendToChannel}
        onUnfollowThread={onUnfollowThread}
        presentation="menu"
        reactionErrorMessage={reactionErrorMessage}
        reactions={reactions}
      />
    </div>
  );
}
