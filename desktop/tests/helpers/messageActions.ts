import { expect, type Locator } from "@playwright/test";

export async function openMessageActions(row: Locator) {
  await row.hover();
  const trigger = row.getByRole("button", { name: "More actions" });
  await expect(trigger).toBeVisible();
  await expect(trigger).toHaveAttribute("data-state", "closed");
  await trigger.click();

  const menu = row.page().getByRole("menu");
  await expect(menu).toBeVisible();
  return menu;
}

export async function selectMessageAction(row: Locator, name: string) {
  const menu = await openMessageActions(row);
  await menu.getByRole("menuitem", { name, exact: true }).click();
}

export async function openMessageReactionPicker(row: Locator) {
  const menu = await openMessageActions(row);
  await menu.getByRole("button", { name: "Open reactions" }).click();
}

export async function selectMessageQuickReaction(
  row: Locator,
  name: string | RegExp,
) {
  const menu = await openMessageActions(row);
  const reaction = menu.getByRole("button", { name }).first();
  await expect(reaction).toBeVisible();
  await reaction.click();
}
