import * as React from "react";

import {
  INBOX_LOADING_DRAFT_KEY,
  loadDraftEntry,
  persistDraftEntry,
} from "@/features/messages/lib/useDrafts";

const PLACEHOLDER = "Write a reply…";

/** Draft-backed input shown while Inbox resolves the conversation to reply to. */
export function LoadingInboxComposer() {
  const initialDraftRef = React.useRef(loadDraftEntry(INBOX_LOADING_DRAFT_KEY));
  const [content, setContent] = React.useState(
    () => initialDraftRef.current?.content ?? "",
  );

  const persistContent = React.useCallback((nextContent: string) => {
    const initialDraft = initialDraftRef.current;
    persistDraftEntry(
      INBOX_LOADING_DRAFT_KEY,
      nextContent,
      "",
      initialDraft?.pendingImeta ?? [],
      initialDraft?.spoileredAttachmentUrls ?? [],
      initialDraft?.mentionRefs ?? [],
    );
  }, []);

  return (
    <textarea
      aria-label={PLACEHOLDER}
      className="block min-h-5 w-full resize-none overflow-hidden border-0 bg-transparent p-0 text-sm leading-5 text-foreground outline-hidden placeholder:text-muted-foreground"
      data-testid="home-loading-inbox-composer"
      onChange={(event) => {
        const nextContent = event.currentTarget.value;
        setContent(nextContent);
        persistContent(nextContent);
      }}
      placeholder={PLACEHOLDER}
      rows={1}
      spellCheck="true"
      value={content}
    />
  );
}
