import { Check, ChevronDown, Hash, Lock, Search } from "lucide-react";
import * as React from "react";

import type { Channel } from "@/shared/api/types";
import { cn } from "@/shared/lib/cn";
import { Popover, PopoverContent, PopoverTrigger } from "@/shared/ui/popover";

function ChannelPrivacyIcon({ channel }: { channel: Channel }) {
  const Icon = channel.visibility === "private" ? Lock : Hash;

  return <Icon aria-hidden className="h-5 w-5 shrink-0" />;
}

type ChannelComboboxProps = {
  allowEmpty?: boolean;
  ariaLabel?: string;
  channels: Channel[];
  disabled?: boolean;
  emptyLabel?: string;
  id?: string;
  isChannelDisabled?: (channel: Channel) => boolean;
  onChange: (value: string) => void;
  variant?: "header" | "field";
  value: string;
};

export function ChannelCombobox({
  allowEmpty = false,
  ariaLabel = "Channel",
  channels,
  disabled,
  emptyLabel = "Choose a channel",
  id,
  isChannelDisabled,
  onChange,
  variant = "header",
  value,
}: ChannelComboboxProps) {
  const [open, setOpen] = React.useState(false);
  const [query, setQuery] = React.useState("");
  const [highlightedIndex, setHighlightedIndex] = React.useState(0);

  const selected = channels.find((c) => c.id === value);

  const filtered = React.useMemo(() => {
    if (!query) return channels;
    const q = query.toLowerCase();
    return channels.filter(
      (c) =>
        c.name.toLowerCase().includes(q) ||
        c.channelType?.toLowerCase().includes(q) ||
        c.id.toLowerCase().includes(q),
    );
  }, [channels, query]);
  const selectable = React.useMemo(
    () => filtered.filter((channel) => !isChannelDisabled?.(channel)),
    [filtered, isChannelDisabled],
  );

  function handleOpenChange(next: boolean) {
    setOpen(next);
    if (!next) {
      setQuery("");
      setHighlightedIndex(0);
    }
  }

  function selectChannel(channelId: string) {
    onChange(channelId);
    handleOpenChange(false);
  }

  function handleKeyDown(e: React.KeyboardEvent) {
    if (selectable.length === 0) return;

    switch (e.key) {
      case "ArrowDown": {
        e.preventDefault();
        setHighlightedIndex((i) => (i + 1) % selectable.length);
        break;
      }
      case "ArrowUp": {
        e.preventDefault();
        setHighlightedIndex(
          (i) => (i - 1 + selectable.length) % selectable.length,
        );
        break;
      }
      case "Enter": {
        e.preventDefault();
        const target = selectable[highlightedIndex];
        if (target) selectChannel(target.id);
        break;
      }
      case "Escape": {
        e.preventDefault();
        handleOpenChange(false);
        break;
      }
    }
  }

  return (
    <Popover onOpenChange={handleOpenChange} open={open}>
      <PopoverTrigger asChild>
        <button
          aria-label={ariaLabel}
          aria-expanded={open}
          className={cn(
            "group flex w-full items-center rounded-lg px-3 py-2 focus-visible:outline-hidden focus-visible:ring-1 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-50",
            variant === "header" &&
              "justify-center border-0 bg-transparent text-lg font-semibold",
            variant === "field" &&
              "justify-between border border-input/40 bg-background text-sm font-normal",
            !selected && "text-muted-foreground",
          )}
          disabled={disabled}
          id={id}
          role="combobox"
          type="button"
        >
          <span
            className={cn(
              "flex min-w-0 items-center gap-2",
              variant === "header" && "justify-center",
            )}
          >
            {selected ? <ChannelPrivacyIcon channel={selected} /> : null}
            <span className="truncate">
              {selected
                ? selected.name
                : value
                  ? "Unavailable channel"
                  : emptyLabel}
            </span>
          </span>
          <ChevronDown className="ml-1 h-5 w-5 shrink-0 text-muted-foreground opacity-50 transition-opacity group-hover:opacity-100 group-focus-visible:opacity-100" />
        </button>
      </PopoverTrigger>
      <PopoverContent
        align="start"
        className="w-(--radix-popover-trigger-width) p-0"
        portalled={variant === "field"}
      >
        <div className="flex items-center gap-2 border-b border-border px-3 py-2">
          <Search className="h-4 w-4 shrink-0 text-muted-foreground" />
          <input
            autoCapitalize="none"
            autoComplete="off"
            autoCorrect="off"
            ref={(el) => el?.focus()}
            className="flex-1 bg-transparent text-sm outline-hidden placeholder:text-muted-foreground"
            onChange={(e) => {
              setQuery(e.target.value);
              setHighlightedIndex(0);
            }}
            onKeyDown={handleKeyDown}
            placeholder="Search channels..."
            spellCheck={false}
            value={query}
          />
        </div>
        <div
          className="max-h-60 overflow-y-auto p-1"
          data-testid="channel-combobox-list"
        >
          {allowEmpty && !query ? (
            <button
              className={cn(
                "flex w-full items-center gap-2 rounded-lg px-2 py-1.5 text-left text-sm transition-colors hover:bg-accent hover:text-accent-foreground",
                !value && "bg-accent/50",
              )}
              onClick={() => selectChannel("")}
              type="button"
            >
              <span className="h-5 w-5 shrink-0" />
              <span className="truncate">{emptyLabel}</span>
              <Check
                className={cn(
                  "ml-auto h-4 w-4 shrink-0",
                  !value ? "opacity-100" : "opacity-0",
                )}
              />
            </button>
          ) : null}
          {filtered.length === 0 ? (
            <p className="px-3 py-4 text-center text-xs text-muted-foreground">
              No channels found.
            </p>
          ) : (
            filtered.map((channel) => {
              const optionDisabled = isChannelDisabled?.(channel) ?? false;
              return (
                <button
                  className={cn(
                    "flex w-full items-center gap-2 rounded-lg px-2 py-1.5 text-left text-sm transition-colors hover:bg-accent hover:text-accent-foreground disabled:cursor-not-allowed disabled:opacity-45 disabled:hover:bg-transparent disabled:hover:text-foreground",
                    channel.id === value && "bg-accent/50",
                    channel.id === selectable[highlightedIndex]?.id &&
                      !optionDisabled &&
                      "bg-accent text-accent-foreground",
                  )}
                  disabled={optionDisabled}
                  key={channel.id}
                  onClick={() => selectChannel(channel.id)}
                  type="button"
                >
                  <ChannelPrivacyIcon channel={channel} />
                  <span className="truncate">
                    {channel.name}{" "}
                    <span className="text-muted-foreground">
                      · {channel.channelType}
                    </span>
                  </span>
                  <Check
                    className={cn(
                      "ml-auto h-4 w-4 shrink-0",
                      channel.id === value ? "opacity-100" : "opacity-0",
                    )}
                  />
                </button>
              );
            })
          )}
        </div>
      </PopoverContent>
    </Popover>
  );
}
