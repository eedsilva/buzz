import { Button } from "@/shared/ui/button";

export function ThreadRepliesLoadState({
  error,
  onRetry,
}: {
  error: string;
  onRetry?: () => void;
}) {
  return (
    <div
      className="rounded-lg border border-destructive/30 bg-destructive/5 p-3 text-sm"
      data-testid="message-thread-replies-error"
      role="alert"
    >
      <p>{error}</p>
      {onRetry ? (
        <Button className="mt-2" onClick={onRetry} size="sm" variant="outline">
          Try again
        </Button>
      ) : null}
    </div>
  );
}
