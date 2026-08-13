import { expect, test } from "@playwright/test";

import { installMockBridge } from "../helpers/bridge";

const TRIGGER_OPTION_LABELS: Record<string, string> = {
  diff_posted: "Diff Posted",
  message_posted: "Message Posted",
  reaction_added: "Reaction Added",
  schedule: "Schedule",
  webhook: "Webhook",
};

test.beforeEach(async ({ page }) => {
  await installMockBridge(page);
});

async function navigateToWorkflows(page: import("@playwright/test").Page) {
  await page.goto("/");
  await page.getByTestId("open-workflows-view").click();
  await expect(page).toHaveURL(/#\/workflows$/);
  await expect(page.getByTestId("workflows-view")).toBeVisible();
}

async function selectFirstChannel(dialog: import("@playwright/test").Locator) {
  await dialog.getByRole("combobox", { name: "Channel" }).click();
  await dialog
    .getByTestId("channel-combobox-list")
    .getByRole("button")
    .first()
    .click();
}

async function expectUnsupportedActionWarnings(
  menu: import("@playwright/test").Locator,
) {
  await expect(menu.getByRole("menuitem")).toHaveText([
    "Delay",
    "Send Message",
    "Call Webhook",
    "Send DM",
    "Request Approval",
    "Add Reaction",
    "Set Channel Topic",
  ]);

  for (const label of [
    "Send DM",
    "Request Approval",
    "Add Reaction",
    "Set Channel Topic",
  ]) {
    await expect(
      menu
        .getByRole("menuitem", { name: label })
        .getByRole("img", { name: "Not supported yet" }),
    ).toBeVisible();
  }

  for (const label of ["Delay", "Send Message", "Call Webhook"]) {
    await expect(
      menu
        .getByRole("menuitem", { name: label, exact: true })
        .getByRole("img", { name: "Not supported yet" }),
    ).toHaveCount(0);
  }
}

async function createWorkflow(
  page: import("@playwright/test").Page,
  name: string,
  options?: {
    description?: string;
    enabled?: boolean;
    trigger?: string;
    stepCondition?: string;
    stepName?: string;
    stepTimeoutSecs?: string;
  },
) {
  await page.getByRole("button", { name: "Create Workflow" }).click();
  const dialog = page.getByRole("dialog");
  await expect(dialog).toBeVisible();
  await expect(dialog.getByText("Choose a channel")).toBeVisible();
  await expect(
    dialog.getByRole("button", { name: "Create workflow" }),
  ).toBeDisabled();
  await selectFirstChannel(dialog);

  await dialog.getByLabel("Workflow name").fill(name);
  if (options?.description) {
    await dialog.getByLabel("Description (optional)").fill(options.description);
  }
  if (options?.enabled === false) {
    await dialog.getByLabel("Enable").click();
  }
  if (options?.trigger) {
    await dialog.getByRole("button", { name: /^Trigger:/ }).click();
    await dialog.getByLabel("Trigger event").click();
    await page
      .getByRole("menuitem", { name: TRIGGER_OPTION_LABELS[options.trigger] })
      .click();
  }

  await dialog.getByRole("button", { name: "Add step" }).click();
  await page.getByRole("menuitem", { name: "Delay" }).click();
  if (options?.stepName) {
    await dialog.getByLabel("Name (optional)").fill(options.stepName);
  }
  if (options?.stepCondition) {
    await dialog
      .getByRole("group", { name: "Condition (optional)" })
      .getByRole("button", { name: "Custom" })
      .click();
    await dialog.getByLabel("Custom expression").fill(options.stepCondition);
  }
  if (options?.stepTimeoutSecs) {
    await dialog.getByLabel("Timeout (seconds)").fill(options.stepTimeoutSecs);
  }

  await dialog.getByRole("button", { name: "Create workflow" }).click();

  await expect(
    page.getByRole("heading", { name: "Create workflow" }),
  ).not.toBeVisible();
}

test("navigates to workflows view and shows empty state", async ({ page }) => {
  await navigateToWorkflows(page);

  await expect(page.getByText("No workflows yet")).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Create your first workflow" }),
  ).toBeVisible();
});

test("creates a workflow via the form builder", async ({ page }) => {
  const workflowName = `test_workflow_${Date.now()}`;

  await navigateToWorkflows(page);
  await createWorkflow(page, workflowName);

  // Verify workflow appears in the list
  await expect(page.getByTestId("workflows-view")).toContainText(workflowName);
});

test("disables autocapitalization in the workflow form", async ({ page }) => {
  await navigateToWorkflows(page);

  await page.getByRole("button", { name: "Create Workflow" }).click();
  const dialog = page.getByRole("dialog");

  await expect(dialog.getByLabel("Workflow name")).toHaveAttribute(
    "autocapitalize",
    "off",
  );

  await dialog.getByRole("button", { name: "Add step" }).click();
  await page.getByRole("menuitem", { name: "Delay" }).click();
  await expect(dialog.getByLabel("Name (optional)")).toHaveAttribute(
    "autocapitalize",
    "off",
  );
});

test("configures common schedules and exposes custom cron", async ({
  page,
}) => {
  await navigateToWorkflows(page);

  await page.getByRole("button", { name: "Create Workflow" }).click();
  const dialog = page.getByRole("dialog");
  await dialog.getByRole("button", { name: /^Trigger:/ }).click();
  const inspector = dialog.getByTestId("workflow-node-inspector");
  await inspector.getByLabel("Trigger event").click();
  await page.getByRole("menuitem", { name: "Schedule" }).click();

  const repeatOptions = inspector.getByRole("radio");
  await expect(repeatOptions).toHaveCount(7);
  await expect(repeatOptions.first()).toHaveAccessibleName("Every 15 minutes");
  await expect(repeatOptions.last()).toHaveAccessibleName("Custom");
  await expect(inspector.getByRole("radio", { name: "Daily" })).toBeChecked();
  await expect(inspector.getByLabel("Run time (UTC)")).toHaveValue("09:00");

  await inspector.getByText("Monthly", { exact: true }).click();
  await inspector.getByLabel("Day of month").selectOption("31");
  await expect(
    inspector.getByText("This schedule won’t run in some months."),
  ).toBeVisible();
  await dialog.getByRole("tab", { name: "YAML" }).click();
  await expect(dialog.getByLabel("Workflow YAML")).toHaveValue(
    /cron: 0 9 31 \* \*/,
  );
  await dialog.getByRole("tab", { name: "Form" }).click();
  await dialog.getByRole("button", { name: /^Trigger:/ }).click();

  await inspector.getByText("Weekly", { exact: true }).click();
  const weekdayPicker = inspector.getByRole("group", { name: "Repeat on" });
  await weekdayPicker.getByText("T", { exact: true }).nth(1).click();
  await expect(
    weekdayPicker.getByRole("checkbox", { name: "Monday" }),
  ).toBeChecked();
  await expect(
    weekdayPicker.getByRole("checkbox", { name: "Thursday" }),
  ).toBeChecked();
  await inspector.getByLabel("Run time (UTC)").fill("14:30");
  await dialog.getByRole("tab", { name: "YAML" }).click();
  await expect(dialog.getByLabel("Workflow YAML")).toHaveValue(
    /cron: 30 14 \* \* 1,4/,
  );
  await dialog.getByRole("tab", { name: "Form" }).click();
  await dialog.getByRole("button", { name: /^Trigger:/ }).click();
  await dialog.getByText("Custom", { exact: true }).click();
  const cronInput = inspector.getByRole("group", { name: "Cron expression" });
  const minuteField = cronInput.getByRole("textbox", { name: "Minute" });
  await expect(cronInput).toBeVisible();
  await expect(minuteField).toHaveValue("30");
  await expect(cronInput.getByRole("textbox", { name: "Hour" })).toHaveValue(
    "14",
  );
  await expect(cronInput.getByRole("textbox", { name: "Weekday" })).toHaveValue(
    "1,4",
  );

  await minuteField.fill("60");
  await expect(
    inspector.getByText("Minute must be between 0 and 59."),
  ).toBeVisible();

  await page.context().grantPermissions(["clipboard-read", "clipboard-write"]);
  await page.evaluate(() => navigator.clipboard.writeText("0 */2 * * 1,3,5"));
  await minuteField.press("ControlOrMeta+V");
  await expect(minuteField).toHaveValue("0");
  await expect(cronInput.getByRole("textbox", { name: "Hour" })).toHaveValue(
    "*/2",
  );
  await expect(cronInput.getByRole("textbox", { name: "Weekday" })).toHaveValue(
    "1,3,5",
  );

  await dialog.getByRole("tab", { name: "YAML" }).click();
  await expect(dialog.getByLabel("Workflow YAML")).toHaveValue(
    /cron: 0 \*\/2 \* \* 1,3,5/,
  );
});

test("builds a valid trigger condition from plain-language choices", async ({
  page,
}) => {
  await navigateToWorkflows(page);

  await page.getByRole("button", { name: "Create Workflow" }).click();
  const dialog = page.getByRole("dialog");
  await dialog.getByRole("button", { name: /^Trigger:/ }).click();
  const inspector = dialog.getByTestId("workflow-node-inspector");

  const conditionFields = inspector.getByRole("group", {
    name: "Condition (optional)",
  });
  const conditionOptions = conditionFields.getByRole("button");
  await expect(conditionOptions).toHaveCount(5);
  await expect(
    conditionFields.getByRole("button", { name: "Message text" }),
  ).toHaveAttribute("aria-pressed", "false");
  for (const name of ["Author pubkey", "Channel ID", "Message ID", "Custom"]) {
    await expect(conditionFields.getByRole("button", { name })).toBeVisible();
  }

  await conditionFields.getByRole("button", { name: "Message text" }).click();
  await inspector.getByLabel("Text to match").fill('deploy "buzz"');
  await dialog.getByRole("tab", { name: "YAML" }).click();
  await expect(dialog.getByLabel("Workflow YAML")).toHaveValue(
    /str_contains\(trigger_text, "deploy \\"buzz\\""\)/,
  );

  await dialog.getByRole("tab", { name: "Form" }).click();
  await dialog.getByRole("button", { name: /^Trigger:/ }).click();
  const roundTrippedFields = inspector.getByRole("group", {
    name: "Condition (optional)",
  });
  await expect(
    roundTrippedFields.getByRole("button", { name: "Message text" }),
  ).toHaveAttribute("aria-pressed", "true");
  const customCondition = roundTrippedFields.getByRole("button", {
    name: "Custom",
  });
  await customCondition.click();
  await expect(inspector.getByLabel("Custom expression")).toHaveValue(
    'str_contains(trigger_text, "deploy \\"buzz\\"")',
  );
  await expect(inspector.getByText(/Use an evalexpr expression/)).toBeVisible();
  await customCondition.click();
  await expect(customCondition).toHaveAttribute("aria-pressed", "false");
  await expect(inspector.getByLabel("Custom expression")).not.toBeVisible();
});

test("chooses and clears a reaction trigger with the app emoji picker", async ({
  page,
}) => {
  await navigateToWorkflows(page);

  await page.getByRole("button", { name: "Create Workflow" }).click();
  const dialog = page.getByRole("dialog");
  await dialog.getByRole("button", { name: /^Trigger:/ }).click();
  const inspector = dialog.getByTestId("workflow-node-inspector");
  await inspector.getByLabel("Trigger event").click();
  await page.getByRole("menuitem", { name: "Reaction Added" }).click();

  const trigger = inspector.getByRole("button", {
    name: "Choose emoji filter",
  });
  await expect(trigger).toContainText("Choose a reaction");
  await trigger.click();

  const picker = page.locator("em-emoji-picker");
  await picker.locator("input[type='search']").fill("buzz");
  await picker.getByRole("button", { name: ":buzz:" }).first().click();

  await expect(trigger).toContainText(":buzz:");
  await dialog.getByRole("tab", { name: "YAML" }).click();
  await expect(dialog.getByLabel("Workflow YAML")).toHaveValue(/:buzz:/);

  await dialog.getByRole("tab", { name: "Form" }).click();
  await dialog.getByRole("button", { name: /^Trigger:/ }).click();
  await dialog.getByRole("button", { name: "Clear emoji filter" }).click();
  await expect(
    dialog.getByRole("button", { name: "Choose emoji filter" }),
  ).toContainText("Choose a reaction");
});

test("chooses an add-reaction step emoji with the app emoji picker", async ({
  page,
}) => {
  await navigateToWorkflows(page);

  await page.getByRole("button", { name: "Create Workflow" }).click();
  const dialog = page.getByRole("dialog");
  await dialog.getByRole("button", { name: "Add step" }).click();
  await expectUnsupportedActionWarnings(page.getByRole("menu"));
  await page.getByRole("menuitem", { name: "Add Reaction" }).click();

  const inspector = dialog.getByTestId("workflow-node-inspector");
  await expect(inspector).toContainText(
    "Backend note: `add_reaction` is not executed yet, so runs fail at this step.",
  );
  await inspector.getByRole("button", { name: "Action", exact: true }).click();
  await expectUnsupportedActionWarnings(page.getByRole("menu"));
  await page.keyboard.press("Escape");
  const stepEmoji = inspector.getByRole("button", {
    name: "Choose reaction emoji",
  });
  await expect(stepEmoji).toContainText("Choose a reaction");
  await stepEmoji.click();

  const picker = page.locator("em-emoji-picker");
  await picker.locator("input[type='search']").fill("buzz");
  await picker.getByRole("button", { name: ":buzz:" }).first().click();

  await expect(stepEmoji).toContainText(":buzz:");
  await dialog.getByRole("tab", { name: "YAML" }).click();
  await expect(dialog.getByLabel("Workflow YAML")).toHaveValue(
    /action: add_reaction[\s\S]*emoji: ":buzz:"/,
  );
});

test("chooses a reaction emoji condition with the app emoji picker", async ({
  page,
}) => {
  await navigateToWorkflows(page);

  await page.getByRole("button", { name: "Create Workflow" }).click();
  const dialog = page.getByRole("dialog");
  await dialog.getByRole("button", { name: /^Trigger:/ }).click();
  let inspector = dialog.getByTestId("workflow-node-inspector");
  await inspector.getByLabel("Trigger event").click();
  await page.getByRole("menuitem", { name: "Reaction Added" }).click();

  await dialog.getByRole("button", { name: "Add step" }).click();
  await page.getByRole("menuitem", { name: "Delay" }).click();
  inspector = dialog.getByTestId("workflow-node-inspector");
  await inspector.getByRole("button", { name: "Reaction emoji" }).click();

  const conditionEmoji = inspector.getByRole("button", {
    name: "Choose condition emoji",
  });
  await conditionEmoji.click();
  const picker = page.locator("em-emoji-picker");
  await picker.locator("input[type='search']").fill("buzz");
  await picker.getByRole("button", { name: ":buzz:" }).first().click();

  await expect(conditionEmoji).toContainText(":buzz:");
  await dialog.getByRole("tab", { name: "YAML" }).click();
  await expect(dialog.getByLabel("Workflow YAML")).toHaveValue(
    /trigger_emoji[\s\S]*:buzz:/,
  );
});

test("switches an empty workflow between form and YAML modes", async ({
  page,
}) => {
  await navigateToWorkflows(page);

  await page.getByRole("button", { name: "Create Workflow" }).click();
  const dialog = page.getByRole("dialog");

  await dialog.getByRole("tab", { name: "YAML" }).click();
  await expect(dialog.getByLabel("Workflow YAML")).toBeVisible();

  await dialog.getByRole("tab", { name: "Form" }).click();
  await expect(dialog.getByLabel("Workflow name")).toBeVisible();
});

test("confirms before discarding workflow changes", async ({ page }) => {
  await navigateToWorkflows(page);

  await page.getByRole("button", { name: "Create Workflow" }).click();
  const dialog = page.getByRole("dialog", { name: "Create workflow" });
  await dialog.getByLabel("Workflow name").fill("unfinished_workflow");
  await dialog.getByRole("button", { name: "Cancel" }).click();

  const confirmation = page.getByRole("alertdialog");
  await expect(confirmation).toContainText("Discard changes?");
  await confirmation.getByRole("button", { name: "Keep editing" }).click();
  await expect(confirmation).not.toBeVisible();
  await expect(dialog.getByLabel("Workflow name")).toHaveValue(
    "unfinished_workflow",
  );

  await dialog.getByRole("button", { name: "Cancel" }).click();
  await confirmation.getByRole("button", { name: "Discard changes" }).click();
  await expect(dialog).not.toBeVisible();
});

test("scrolls the channel list with the mouse wheel", async ({ page }) => {
  await navigateToWorkflows(page);

  await page.getByRole("button", { name: "Create Workflow" }).click();
  const dialog = page.getByRole("dialog");
  await dialog.getByRole("combobox", { name: "Channel" }).click();

  const channelList = page.getByTestId("channel-combobox-list");
  await expect(channelList).toBeVisible();
  await channelList.hover();
  await page.mouse.wheel(0, 500);

  await expect
    .poll(() => channelList.evaluate((element) => element.scrollTop))
    .toBeGreaterThan(0);
});

test("selects a message destination from the channel lookup", async ({
  page,
}) => {
  await navigateToWorkflows(page);

  await page.getByRole("button", { name: "Create Workflow" }).click();
  const dialog = page.getByRole("dialog");
  await selectFirstChannel(dialog);
  await dialog.getByRole("button", { name: "Add step" }).click();
  await page.getByRole("menuitem", { name: "Send Message" }).click();

  const channelOverride = dialog.getByRole("combobox", {
    name: "Channel override (optional)",
  });
  await expect(channelOverride).toContainText("Use workflow channel");
  await channelOverride.click();

  const search = page.getByPlaceholder("Search channels...");
  await search.fill("random");
  await expect(
    page.getByRole("button", { name: "random · stream" }),
  ).toBeDisabled();

  await search.fill("agents");
  await page.getByRole("button", { name: "agents · stream" }).click();
  await expect(channelOverride).toContainText("agents");

  await dialog.getByRole("tab", { name: "YAML" }).click();
  await expect(dialog.getByLabel("Workflow YAML")).toHaveValue(
    /channel: [0-9a-f-]{36}/,
  );
});

test("opens node configuration in a contextual inspector", async ({ page }) => {
  await navigateToWorkflows(page);

  await page.getByRole("button", { name: "Create Workflow" }).click();
  const dialog = page.getByRole("dialog");
  const inspector = dialog.getByTestId("workflow-node-inspector");

  await expect(inspector).not.toBeVisible();
  await expect(dialog.getByText("End", { exact: true })).not.toBeVisible();

  await dialog.getByRole("button", { name: /^Trigger:/ }).click();
  await expect(inspector).toBeVisible();
  await expect(inspector.getByLabel("Trigger event")).toHaveAttribute(
    "data-value",
    "message_posted",
  );

  await dialog.getByRole("button", { name: "Add step" }).click();
  await page.getByRole("menuitem", { name: "Send Message" }).click();
  const triggerNode = dialog.getByRole("button", { name: /^Trigger:/ });
  const stepNode = dialog.getByRole("button", { name: /^Step 1:/ });
  await expect(inspector.getByLabel("Step ID")).toHaveValue("step_1");
  await expect(inspector.getByLabel("Action")).toHaveAttribute(
    "data-value",
    "send_message",
  );
  await expect(inspector.getByLabel("Message text")).toBeVisible();
  await expect(dialog.getByText("End", { exact: true })).toBeVisible();
  await expect(triggerNode).toHaveAttribute("aria-pressed", "false");
  await expect(stepNode).toHaveAttribute("aria-pressed", "true");
  expect(
    await triggerNode.evaluate(
      (element) => getComputedStyle(element).outlineColor,
    ),
  ).not.toBe(
    await stepNode.evaluate(
      (element) => getComputedStyle(element).outlineColor,
    ),
  );
  await expect
    .poll(() =>
      inspector.evaluate((element) => getComputedStyle(element).padding),
    )
    .toBe("16px");

  await inspector.getByLabel("Action").click();
  await page.getByRole("menuitem", { name: "Send DM" }).click();
  await expect(inspector.getByLabel("Action")).toHaveAttribute(
    "data-value",
    "send_dm",
  );
  await expect(inspector.getByLabel("To (pubkey)")).toBeVisible();

  await inspector.getByLabel("Name (optional)").fill("Notify deployer");
  await expect(stepNode).toContainText("Notify deployer");
  await expect(stepNode).toContainText("Send DM");
  await expect(stepNode).toHaveAttribute("aria-pressed", "true");

  await stepNode.hover();
  const removeStep = dialog.getByRole("button", { name: "Remove Step 1" });
  await expect(removeStep).toBeVisible();
  await removeStep.click();
  await expect(stepNode).not.toBeVisible();
  await expect(inspector).toBeVisible();
  await expect(inspector.getByLabel("Trigger event")).toBeVisible();
  await expect(dialog.getByText("End", { exact: true })).not.toBeVisible();
});

test("switches between the form and YAML editors", async ({ page }) => {
  await navigateToWorkflows(page);

  await page.getByRole("button", { name: "Create Workflow" }).click();
  const dialog = page.getByRole("dialog");
  const nameInput = dialog.getByLabel("Workflow name");

  await nameInput.fill("yaml_round_trip");
  await dialog.getByRole("tab", { name: "YAML" }).click();
  await expect(dialog.getByLabel("Workflow YAML")).toHaveValue(
    /name: yaml_round_trip/,
  );

  await dialog.getByRole("tab", { name: "Form" }).click();
  await expect(nameInput).toHaveValue("yaml_round_trip");
});

test("captures disabled diff workflows in the list UI", async ({ page }) => {
  const workflowName = `diff_workflow_${Date.now()}`;
  const description = "Watches diff events for src/ changes";

  await navigateToWorkflows(page);
  await createWorkflow(page, workflowName, {
    description,
    enabled: false,
    trigger: "diff_posted",
    stepName: "Notify reviewers",
    stepCondition: 'str_contains(trigger_text, "src/")',
    stepTimeoutSecs: "45",
  });

  const card = page
    .locator('[data-testid^="workflow-card-"]')
    .filter({ hasText: workflowName })
    .first();
  await expect(card).toContainText(workflowName);
  await expect(card).toContainText("When a diff is posted, wait for a moment");
  await expect(card).toContainText(description);
  await expect(card).toContainText("Diff Posted");
  await expect(card).toContainText("disabled");
});

test("shows the webhook secret dialog after saving a webhook workflow", async ({
  page,
}) => {
  const workflowName = `webhook_workflow_${Date.now()}`;

  await navigateToWorkflows(page);
  await createWorkflow(page, workflowName, {
    trigger: "webhook",
  });

  await expect(page.getByText("Webhook Ready")).toBeVisible();
  await expect(page.getByRole("button", { name: "Copy URL" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Copy Secret" })).toBeVisible();

  await page.getByRole("button", { name: "Close" }).click();
  await expect(page.getByText("Webhook Ready")).not.toBeVisible();
});

test("edits an existing workflow", async ({ page }) => {
  const originalName = `edit_test_${Date.now()}`;
  const updatedName = `${originalName}_updated`;

  await navigateToWorkflows(page);
  await createWorkflow(page, originalName);

  // Verify it exists
  await expect(page.getByTestId("workflows-view")).toContainText(originalName);

  // Open the dropdown menu and click Edit
  await page.getByRole("button", { name: "Workflow actions" }).first().click();
  await page.getByRole("menuitem", { name: "Edit" }).click();

  // Dialog should open in edit mode
  await expect(page.getByRole("dialog")).toBeVisible();
  await expect(page.getByText("Edit workflow")).toBeVisible();

  // Change the name
  const nameInput = page.getByLabel("Workflow name");
  await nameInput.clear();
  await nameInput.fill(updatedName);

  // Save
  await page.getByRole("button", { name: "Save changes" }).click();
  await expect(page.getByRole("dialog")).not.toBeVisible();

  // Verify the updated name appears
  await expect(page.getByTestId("workflows-view")).toContainText(updatedName);
});

test("duplicates a workflow", async ({ page }) => {
  const originalName = `dup_test_${Date.now()}`;

  await navigateToWorkflows(page);
  await createWorkflow(page, originalName);

  // Open the dropdown menu and click Duplicate
  await page.getByRole("button", { name: "Workflow actions" }).first().click();
  await page.getByRole("menuitem", { name: "Duplicate" }).click();

  // Dialog should open in duplicate mode with "(copy)" suffix
  await expect(page.getByRole("dialog")).toBeVisible();
  await expect(page.getByText("Duplicate workflow")).toBeVisible();

  // Submit the duplicate
  await selectFirstChannel(page.getByRole("dialog"));
  await page.getByRole("button", { name: "Create copy" }).click();
  await expect(page.getByRole("dialog")).not.toBeVisible();

  // Both the original and copy should exist
  await expect(page.getByTestId("workflows-view")).toContainText(originalName);
});

test("deletes a workflow with confirmation", async ({ page }) => {
  const workflowName = `delete_test_${Date.now()}`;

  await navigateToWorkflows(page);
  await createWorkflow(page, workflowName);

  // Verify it exists
  await expect(page.getByTestId("workflows-view")).toContainText(workflowName);

  // Open the dropdown menu and click Delete
  await page.getByRole("button", { name: "Workflow actions" }).first().click();
  await page.getByRole("menuitem", { name: "Delete" }).click();

  // Confirmation dialog should appear with workflow name
  await expect(page.getByRole("alertdialog")).toBeVisible();
  await expect(page.getByRole("alertdialog")).toContainText(workflowName);

  // Confirm deletion
  await page.getByRole("button", { name: "Delete" }).click();
  await expect(page.getByRole("alertdialog")).not.toBeVisible();

  // Verify workflow is gone — back to empty state
  await expect(page.getByText("No workflows yet")).toBeVisible();
});

test("opens a workflow in the edit modal from its card", async ({ page }) => {
  const workflowName = `open_edit_test_${Date.now()}`;

  await navigateToWorkflows(page);
  await createWorkflow(page, workflowName);

  await page.getByRole("button", { name: `Edit ${workflowName}` }).click();

  const dialog = page.getByRole("dialog", { name: "Edit workflow" });
  await expect(dialog).toBeVisible();
  await expect(dialog.getByLabel("Workflow name")).toHaveValue(workflowName);
  await expect(page.getByTestId("workflow-detail-panel")).not.toBeVisible();
});
