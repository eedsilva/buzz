import {
  Check,
  ChevronDown,
  Plus,
  Trash2,
  TriangleAlert,
  X,
  Zap,
} from "lucide-react";
import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import * as React from "react";
import { createPortal } from "react-dom";

import type { Channel } from "@/shared/api/types";
import { Button } from "@/shared/ui/button";
import { cn } from "@/shared/lib/cn";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/shared/ui/dropdown-menu";
import { Input } from "@/shared/ui/input";
import { Switch } from "@/shared/ui/switch";
import { Textarea } from "@/shared/ui/textarea";
import { WorkflowConditionBuilder } from "./WorkflowConditionBuilder";
import { WorkflowEmojiField } from "./WorkflowEmojiField";
import { WorkflowScheduleFields } from "./WorkflowScheduleFields";
import { WorkflowStepCard } from "./WorkflowStepCard";
import { FieldLabel } from "./workflowFormPrimitives";
import {
  DEFAULT_FORM_STATE,
  ACTION_LABELS,
  ACTION_TYPES,
  TRIGGER_LABELS,
  TRIGGER_TYPES,
  UNSUPPORTED_ACTION_TYPES,
  formStateToYaml,
  nextStepId,
  yamlToFormState,
} from "./workflowFormTypes";
import type {
  ActionType,
  StepFormState,
  TriggerConfig,
  WorkflowFormState,
} from "./workflowFormTypes";
import { defaultScheduleTrigger } from "./workflowSchedule";

function TriggerConfigFields({
  disabled,
  trigger,
  onUpdate,
}: {
  disabled?: boolean;
  trigger: TriggerConfig;
  onUpdate: (trigger: TriggerConfig) => void;
}) {
  switch (trigger.on) {
    case "message_posted":
    case "diff_posted":
      return (
        <div>
          <WorkflowConditionBuilder
            disabled={disabled}
            idPrefix="wf-trigger-filter"
            matchAllHint="Leave empty to trigger on every message."
            onChange={(filter) => onUpdate({ ...trigger, filter })}
            triggerType={trigger.on}
            value={trigger.filter ?? ""}
          />
        </div>
      );
    case "reaction_added":
      return (
        <div className="space-y-1.5">
          <FieldLabel htmlFor="wf-trigger-emoji">
            Emoji filter (optional)
          </FieldLabel>
          <WorkflowEmojiField
            ariaLabel="Choose emoji filter"
            clearAriaLabel="Clear emoji filter"
            disabled={disabled}
            id="wf-trigger-emoji"
            onChange={(emoji) => onUpdate({ ...trigger, emoji })}
            value={trigger.emoji}
          />
        </div>
      );
    case "webhook":
      return (
        <p className="text-xs text-muted-foreground">
          A unique URL is generated after creation.
        </p>
      );
    case "schedule":
      return (
        <WorkflowScheduleFields
          disabled={disabled}
          onUpdate={onUpdate}
          trigger={trigger}
        />
      );
    default:
      return null;
  }
}

type WorkflowFormBuilderProps = {
  channels: Channel[];
  disabled?: boolean;
  footerLeadingContainer?: HTMLElement | null;
  mode: WorkflowEditorMode;
  onChange: (yaml: string) => void;
  parseError: string | null;
  scopeField?: React.ReactNode;
  yaml: string;
  workflowChannelId?: string | null;
};

export type WorkflowEditorMode = "form" | "yaml";

type SelectedNode =
  | { type: "trigger" }
  | { type: "step"; index: number }
  | null;

function nodePosition(node: Exclude<SelectedNode, null>): number {
  return node.type === "trigger" ? 0 : node.index + 1;
}

const inspectorContentVariants = {
  enter: (direction: number) => ({
    opacity: 0,
    y: direction < 0 ? 12 : -12,
  }),
  center: { opacity: 1, y: 0 },
  exit: (direction: number) => ({
    opacity: 0,
    y: direction < 0 ? -12 : 12,
  }),
};

function InspectorTypeMenu<T extends string>({
  ariaLabel,
  disabled,
  labels,
  onChange,
  options,
  warningOptions = [],
  value,
}: {
  ariaLabel: string;
  disabled?: boolean;
  labels: Record<T, string>;
  onChange: (value: T) => void;
  options: readonly T[];
  warningOptions?: readonly T[];
  value: T;
}) {
  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <button
          aria-label={ariaLabel}
          className="group inline-flex max-w-full items-center gap-1.5 rounded-md py-0.5 text-base font-semibold text-foreground outline-hidden focus-visible:ring-1 focus-visible:ring-ring"
          data-value={value}
          disabled={disabled}
          type="button"
        >
          <span className="truncate">{labels[value]}</span>
          <ChevronDown className="h-4 w-4 shrink-0 text-muted-foreground opacity-60 transition-opacity group-hover:opacity-100" />
        </button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="start" sideOffset={8}>
        {options.map((option) => (
          <DropdownMenuItem key={option} onSelect={() => onChange(option)}>
            <Check
              className={cn(
                "h-4 w-4",
                option === value ? "opacity-100" : "opacity-0",
              )}
            />
            <span>{labels[option]}</span>
            {warningOptions.includes(option) ? <UnsupportedActionIcon /> : null}
          </DropdownMenuItem>
        ))}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}

function UnsupportedActionIcon() {
  return (
    <TriangleAlert
      aria-label="Not supported yet"
      className="ml-auto h-4 w-4 shrink-0 text-amber-500"
      role="img"
    />
  );
}

function WorkflowNode({
  description,
  disabled,
  icon,
  label,
  number,
  onAddAfter,
  onClick,
  onRemove,
  selected,
  showTitle = true,
  subtitle,
  title,
}: {
  description: string;
  disabled?: boolean;
  icon?: React.ReactNode;
  label: string;
  number?: number;
  onAddAfter: (action: ActionType) => void;
  onClick: () => void;
  onRemove?: () => void;
  selected: boolean;
  showTitle?: boolean;
  subtitle?: string;
  title: string;
}) {
  const isNumbered = number !== undefined;

  return (
    <li className="flex flex-col items-center">
      <div className="group relative isolate w-full after:absolute after:left-full after:top-0 after:z-0 after:h-full after:w-12 after:content-['']">
        <button
          aria-label={label}
          aria-pressed={selected}
          className={cn(
            "relative z-20 flex w-full items-center gap-3 text-left transition-colors",
            "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2",
            "rounded-full bg-muted/25 p-3 outline outline-2 outline-offset-4 outline-muted-foreground/0",
            "data-[selected=true]:bg-muted/70 data-[selected=true]:outline-muted-foreground/20",
            "data-[selected=false]:hover:bg-muted/45",
          )}
          data-selected={selected}
          disabled={disabled}
          onClick={onClick}
          type="button"
        >
          <span
            className={cn(
              "flex h-9 w-9 shrink-0 items-center justify-center",
              "rounded-full bg-muted/60 text-muted-foreground",
              "data-[selected=true]:bg-foreground/15 data-[selected=true]:text-foreground",
              isNumbered && "text-sm font-semibold",
            )}
            data-selected={selected}
          >
            {isNumbered ? number : icon}
          </span>
          <span className="min-w-0 flex-1">
            {showTitle ? (
              <span className="block text-2xs font-semibold uppercase tracking-wide text-muted-foreground/70">
                {title}
              </span>
            ) : null}
            {subtitle ? (
              <span className="block truncate text-2xs font-semibold uppercase tracking-wide text-muted-foreground/70">
                {subtitle}
              </span>
            ) : null}
            <span className="block truncate text-sm font-semibold text-foreground">
              {description}
            </span>
          </span>
        </button>

        {onRemove ? (
          <Button
            aria-label={`Remove ${title}`}
            className="pointer-events-none absolute right-1 top-1/2 z-10 h-8 w-8 -translate-y-1/2 rounded-full bg-transparent opacity-0 transition-all duration-200 group-focus-within:pointer-events-auto group-focus-within:translate-x-12 group-focus-within:opacity-100 group-hover:pointer-events-auto group-hover:translate-x-12 group-hover:opacity-100 hover:bg-destructive/15 hover:text-destructive"
            disabled={disabled}
            onClick={onRemove}
            size="icon"
            type="button"
            variant="ghost"
          >
            <Trash2 className="h-4 w-4" />
          </Button>
        ) : null}
      </div>

      <span className="relative flex h-18 items-center justify-center">
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <Button
              aria-label={
                title === "Trigger" ? "Add step" : `Add after ${title}`
              }
              className="relative z-10 h-7 w-7 rounded-full bg-background shadow-sm"
              disabled={disabled}
              size="icon"
              type="button"
              variant="outline"
            >
              <Plus className="h-3.5 w-3.5" />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="center" side="right" sideOffset={8}>
            {ACTION_TYPES.map((action) => (
              <DropdownMenuItem
                key={action}
                onSelect={() => onAddAfter(action)}
              >
                <span>{ACTION_LABELS[action]}</span>
                {UNSUPPORTED_ACTION_TYPES.includes(action) ? (
                  <UnsupportedActionIcon />
                ) : null}
              </DropdownMenuItem>
            ))}
          </DropdownMenuContent>
        </DropdownMenu>
      </span>
    </li>
  );
}

export function WorkflowFormBuilder({
  channels,
  disabled,
  footerLeadingContainer,
  mode,
  onChange,
  parseError,
  scopeField,
  yaml,
  workflowChannelId,
}: WorkflowFormBuilderProps) {
  // Parse once on mount instead of calling yamlToFormState three times
  const initialParseRef = React.useRef(yaml ? yamlToFormState(yaml) : null);
  const [formState, setFormState] = React.useState<WorkflowFormState>(
    initialParseRef.current?.ok
      ? initialParseRef.current.state
      : DEFAULT_FORM_STATE,
  );
  const [selectedNode, setSelectedNode] = React.useState<SelectedNode>(null);
  const [selectionDirection, setSelectionDirection] = React.useState<1 | -1>(1);
  const shouldReduceMotion = useReducedMotion();
  const previousModeRef = React.useRef(mode);

  const updateFormState = React.useCallback(
    (next: WorkflowFormState) => {
      setFormState(next);
      onChange(formStateToYaml(next));
    },
    [onChange],
  );

  React.useEffect(() => {
    if (previousModeRef.current === mode) return;
    previousModeRef.current = mode;

    if (mode === "yaml") {
      setSelectedNode(null);
      return;
    }

    const result = yamlToFormState(yaml);
    if (result.ok) setFormState(result.state);
  }, [mode, yaml]);

  const selectNode = React.useCallback(
    (nextNode: Exclude<SelectedNode, null>) => {
      if (selectedNode) {
        const currentPosition = nodePosition(selectedNode);
        const nextPosition = nodePosition(nextNode);
        if (nextPosition !== currentPosition) {
          setSelectionDirection(nextPosition < currentPosition ? -1 : 1);
        }
      }
      setSelectedNode(nextNode);
    },
    [selectedNode],
  );

  const insertStep = React.useCallback(
    (index: number, action: ActionType) => {
      const nextSteps = [...formState.steps];
      const newStep: StepFormState = {
        id: nextStepId(formState.steps),
        action,
      };
      if (action === "call_webhook") {
        newStep.method = "POST";
      }
      nextSteps.splice(index, 0, newStep);
      updateFormState({
        ...formState,
        steps: nextSteps,
      });
      selectNode({ type: "step", index });
    },
    [formState, selectNode, updateFormState],
  );

  const removeStep = React.useCallback(
    (index: number) => {
      updateFormState({
        ...formState,
        steps: formState.steps.filter((_, i) => i !== index),
      });

      if (selectedNode?.type !== "step") return;

      if (selectedNode.index === index) {
        setSelectionDirection(-1);
        setSelectedNode(
          index === 0
            ? { type: "trigger" }
            : { type: "step", index: index - 1 },
        );
      } else if (selectedNode.index > index) {
        setSelectionDirection(-1);
        setSelectedNode({ type: "step", index: selectedNode.index - 1 });
      }
    },
    [formState, selectedNode, updateFormState],
  );

  const updateStep = React.useCallback(
    (index: number, step: StepFormState) => {
      const next = [...formState.steps];
      next[index] = step;
      updateFormState({ ...formState, steps: next });
    },
    [formState, updateFormState],
  );

  const selectedStep =
    selectedNode?.type === "step"
      ? formState.steps[selectedNode.index]
      : undefined;

  return (
    <>
      <div className="flex h-full min-h-0 flex-col">
        {parseError ? (
          <p className="mx-6 mt-3 rounded-lg border border-destructive/30 bg-destructive/10 px-3 py-2 text-xs text-destructive">
            Cannot switch to form view: {parseError}
          </p>
        ) : null}

        {mode === "yaml" ? (
          <div className="min-h-0 flex-1 space-y-4 overflow-y-auto p-6">
            <div className="max-w-md">{scopeField}</div>
            <div className="flex h-full min-h-[320px] flex-col space-y-1.5">
              <Textarea
                aria-label="Workflow YAML"
                autoCapitalize="off"
                className="min-h-[320px] flex-1 resize-none font-mono text-xs"
                disabled={disabled}
                onChange={(event) => onChange(event.target.value)}
                value={yaml}
              />
              <p className="text-xs text-muted-foreground">
                Edit the raw YAML definition directly.
              </p>
            </div>
          </div>
        ) : (
          <div className="flex min-h-0 flex-1 flex-col">
            <div className="grid flex-shrink-0 grid-cols-2 items-end gap-3 border-b border-border bg-muted/10 px-6 py-4">
              <div className="space-y-1.5">
                <FieldLabel htmlFor="wf-name">Workflow name</FieldLabel>
                <Input
                  autoCapitalize="off"
                  autoCorrect="off"
                  disabled={disabled}
                  id="wf-name"
                  onChange={(event) =>
                    updateFormState({ ...formState, name: event.target.value })
                  }
                  placeholder="e.g. deploy_notifier"
                  value={formState.name}
                />
              </div>
              <div className="space-y-1.5">
                <FieldLabel htmlFor="wf-description">
                  Description (optional)
                </FieldLabel>
                <Input
                  autoCapitalize="off"
                  disabled={disabled}
                  id="wf-description"
                  onChange={(event) =>
                    updateFormState({
                      ...formState,
                      description: event.target.value,
                    })
                  }
                  placeholder="What does this workflow do?"
                  value={formState.description}
                />
              </div>
            </div>

            <div className="flex min-h-0 flex-1">
              <div className="min-h-0 min-w-0 flex-1 overflow-y-auto px-6 py-5">
                <div className="mx-auto w-full max-w-sm">
                  {scopeField ? <div className="mb-3">{scopeField}</div> : null}
                  <ol aria-label="Workflow sequence">
                    <WorkflowNode
                      description={TRIGGER_LABELS[formState.trigger.on]}
                      disabled={disabled}
                      icon={<Zap className="h-4 w-4" />}
                      label={`Trigger: ${TRIGGER_LABELS[formState.trigger.on]}`}
                      onAddAfter={(action) => insertStep(0, action)}
                      onClick={() => selectNode({ type: "trigger" })}
                      selected={selectedNode?.type === "trigger"}
                      title="Trigger"
                    />

                    {formState.steps.map((step, index) => {
                      const stepName = step.name?.trim();
                      const actionLabel = ACTION_LABELS[step.action];
                      const nodeTitle = stepName || actionLabel;
                      return (
                        <WorkflowNode
                          description={nodeTitle}
                          disabled={disabled}
                          key={step.id}
                          label={`Step ${index + 1}: ${nodeTitle}`}
                          number={index + 1}
                          onAddAfter={(action) => insertStep(index + 1, action)}
                          onClick={() => selectNode({ type: "step", index })}
                          onRemove={() => removeStep(index)}
                          selected={
                            selectedNode?.type === "step" &&
                            selectedNode.index === index
                          }
                          showTitle={false}
                          subtitle={stepName ? actionLabel : undefined}
                          title={`Step ${index + 1}`}
                        />
                      );
                    })}

                    {formState.steps.length > 0 ? (
                      <li className="flex justify-center">
                        <span className="rounded-full border border-border bg-muted/30 px-5 py-1.5 text-xs font-medium text-muted-foreground">
                          End
                        </span>
                      </li>
                    ) : null}
                  </ol>
                </div>
              </div>

              <AnimatePresence initial={false}>
                {selectedNode ? (
                  <motion.aside
                    animate={{ opacity: 1, width: "26rem", x: 0 }}
                    className="flex flex-shrink-0 p-4"
                    data-testid="workflow-node-inspector"
                    exit={{ opacity: 0, width: 0, x: 24 }}
                    initial={{ opacity: 0, width: 0, x: 24 }}
                    key="workflow-node-inspector"
                    transition={
                      shouldReduceMotion
                        ? { duration: 0 }
                        : { duration: 0.24, ease: [0.22, 1, 0.36, 1] }
                    }
                  >
                    <div className="flex min-w-0 flex-1 flex-col overflow-hidden rounded-xl bg-muted/40">
                      <div className="flex w-96 min-w-96 flex-shrink-0 items-start justify-between gap-3 px-5 pb-3 pt-5">
                        <div className="min-w-0">
                          <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
                            {selectedNode.type === "trigger"
                              ? "Trigger"
                              : `Step ${selectedNode.index + 1}`}
                          </p>
                          {selectedNode.type === "trigger" ? (
                            <InspectorTypeMenu
                              ariaLabel="Trigger event"
                              disabled={disabled}
                              labels={TRIGGER_LABELS}
                              onChange={(triggerType) =>
                                updateFormState({
                                  ...formState,
                                  trigger:
                                    triggerType === "schedule"
                                      ? defaultScheduleTrigger()
                                      : { on: triggerType },
                                })
                              }
                              options={TRIGGER_TYPES}
                              value={formState.trigger.on}
                            />
                          ) : selectedStep ? (
                            <InspectorTypeMenu
                              ariaLabel="Action"
                              disabled={disabled}
                              labels={ACTION_LABELS}
                              onChange={(action) => {
                                const next = { ...selectedStep, action };
                                if (action === "call_webhook" && !next.method) {
                                  next.method = "POST";
                                }
                                updateStep(selectedNode.index, next);
                              }}
                              options={ACTION_TYPES}
                              warningOptions={UNSUPPORTED_ACTION_TYPES}
                              value={selectedStep.action}
                            />
                          ) : null}
                        </div>
                        <div className="flex items-center gap-1">
                          {selectedNode.type === "step" && selectedStep ? (
                            <Button
                              aria-label="Remove step"
                              className="h-8 w-8"
                              disabled={disabled}
                              onClick={() => removeStep(selectedNode.index)}
                              size="icon"
                              type="button"
                              variant="ghost"
                            >
                              <Trash2 className="h-4 w-4 text-muted-foreground" />
                            </Button>
                          ) : null}
                          <Button
                            aria-label="Close inspector"
                            className="h-8 w-8"
                            onClick={() => setSelectedNode(null)}
                            size="icon"
                            type="button"
                            variant="ghost"
                          >
                            <X className="h-4 w-4" />
                          </Button>
                        </div>
                      </div>

                      <div className="min-h-0 w-96 min-w-96 flex-1 overflow-y-auto px-5 pb-5 pt-2">
                        <AnimatePresence
                          custom={selectionDirection}
                          initial={false}
                          mode="wait"
                        >
                          <motion.div
                            animate="center"
                            custom={selectionDirection}
                            exit="exit"
                            initial="enter"
                            key={
                              selectedNode.type === "trigger"
                                ? "trigger"
                                : `step-${selectedNode.index}`
                            }
                            transition={
                              shouldReduceMotion
                                ? { duration: 0 }
                                : { duration: 0.15, ease: "easeOut" }
                            }
                            variants={inspectorContentVariants}
                          >
                            {selectedNode.type === "trigger" ? (
                              <div>
                                <TriggerConfigFields
                                  disabled={disabled}
                                  onUpdate={(trigger) =>
                                    updateFormState({ ...formState, trigger })
                                  }
                                  trigger={formState.trigger}
                                />
                              </div>
                            ) : selectedStep ? (
                              <WorkflowStepCard
                                bare
                                channels={channels}
                                disabled={disabled}
                                index={selectedNode.index}
                                onRemove={() => removeStep(selectedNode.index)}
                                onUpdate={(updated) =>
                                  updateStep(selectedNode.index, updated)
                                }
                                previousSteps={formState.steps.slice(
                                  0,
                                  selectedNode.index,
                                )}
                                showHeader={false}
                                step={selectedStep}
                                triggerType={formState.trigger.on}
                                workflowChannelId={workflowChannelId}
                              />
                            ) : null}
                          </motion.div>
                        </AnimatePresence>
                      </div>
                    </div>
                  </motion.aside>
                ) : null}
              </AnimatePresence>
            </div>
          </div>
        )}
      </div>
      {mode === "form" && footerLeadingContainer
        ? createPortal(
            <div className="flex items-center gap-3">
              <label className="text-sm text-foreground" htmlFor="wf-enabled">
                Enable
              </label>
              <Switch
                checked={formState.enabled}
                disabled={disabled}
                id="wf-enabled"
                onCheckedChange={(checked) =>
                  updateFormState({ ...formState, enabled: checked })
                }
              />
            </div>,
            footerLeadingContainer,
          )
        : null}
    </>
  );
}
