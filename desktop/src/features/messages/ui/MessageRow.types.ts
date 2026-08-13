import type { TimelineMessage } from "@/features/messages/types";
import type { UserProfileLookup } from "@/features/profile/lib/identity";
import type { VideoReviewContext } from "@/shared/ui/VideoPlayer";
import type { ReactNode } from "react";

export type ThreadDepthGuideAction = {
  active?: boolean;
  depth: number;
  label: string;
  message: TimelineMessage;
};

export type MessageRowProps = {
  bodyFooter?: ReactNode;
  channelId?: string | null;
  collapseDepthGuideActions?: ReadonlyArray<ThreadDepthGuideAction>;
  collapseDescendantsLabel?: string;
  connectDescendants?: boolean;
  currentPubkey?: string;
  depthGuideDepths?: ReadonlyArray<number>;
  highlighted?: boolean;
  highlightDescendantRail?: boolean;
  highlightReplyConnector?: boolean;
  highlightThreadLineDepths?: ReadonlyArray<number>;
  hoverBackground?: boolean;
  huddleMemberPubkeys?: readonly string[];
  huddleMemberPubkeysPending?: boolean;
  hideAgentAccessBadge?: boolean;
  isContinuation?: boolean;
  isFollowedByContinuation?: boolean;
  isFollowingThread?: boolean;
  isUnread?: boolean;
  layoutVariant?: "default" | "thread-reply";
  message: TimelineMessage;
  onCollapseDepthGuide?: (message: TimelineMessage) => void;
  onCollapseDepthGuideHoverChange?: (
    message: TimelineMessage,
    hovered: boolean,
  ) => void;
  onCollapseDescendants?: (message: TimelineMessage) => void;
  onCollapseDescendantsHoverChange?: (
    message: TimelineMessage,
    hovered: boolean,
  ) => void;
  onDelete?: (message: TimelineMessage) => void;
  onEdit?: (message: TimelineMessage) => void;
  onEntranceComplete?: (messageId: string) => void;
  onFollowThread?: (message: TimelineMessage) => void;
  onMarkRead?: (message: TimelineMessage) => void;
  onMarkUnread?: (message: TimelineMessage) => void;
  onReply?: (message: TimelineMessage) => void;
  onSendToChannel?: (message: TimelineMessage) => Promise<void>;
  onToggleReaction?: (
    message: TimelineMessage,
    emoji: string,
    remove: boolean,
  ) => Promise<void>;
  onUnfollowThread?: (message: TimelineMessage) => void;
  playEntrance?: boolean;
  profiles?: UserProfileLookup;
  searchQuery?: string;
  showDepthGuides?: boolean;
  videoReviewCommentRootId?: string;
  videoReviewContext?: VideoReviewContext;
};
