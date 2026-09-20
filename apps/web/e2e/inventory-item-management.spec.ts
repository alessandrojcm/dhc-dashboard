import { expect, test } from "@playwright/test";
import { loginAsUser } from "./auth";
import { gotoHydrated } from "./hydration";
import {
	createInventoryStructure,
	createMember,
	createUniqueEmail,
} from "./setupFunctions";

const tag = `items-ui-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;

test.describe("ALE-284 operator inventory items", () => {
	test("operator manages an item through its retained lifecycle", async ({
		page,
		context,
	}) => {
		const operator = await createMember({
			email: createUniqueEmail("inventory-item-operator"),
			roles: new Set(["member", "quartermaster"]),
		});
		await createInventoryStructure({
			categoryName: `Blades ${tag}`,
			definitions: [
				{
					label: "Size",
					valueType: "single_select",
					required: true,
					identifyingPosition: 0,
					options: [{ label: "Medium" }],
				},
			],
			containerPath: [`Cage ${tag}`, `Rack ${tag}`],
			operatorActorId: operator.memberId,
		});
		await createInventoryStructure({
			categoryName: `Masks ${tag}`,
			definitions: [
				{
					label: "Colour",
					valueType: "text",
					required: true,
					identifyingPosition: 0,
				},
			],
			containerPath: [`Cupboard ${tag}`],
			operatorActorId: operator.memberId,
		});

		await loginAsUser(context, operator.email);
		await page.setViewportSize({ width: 390, height: 844 });
		await gotoHydrated(page, "/dashboard/inventory/items");
		await expect(
			page.getByRole("heading", { name: "Items", exact: true }),
		).toBeVisible();

		await page.getByRole("link", { name: "New item" }).click();
		await expect(page).toHaveURL(/\/dashboard\/inventory\/items\/new$/);
		await page.getByLabel("Category").click();
		await page.getByRole("option", { name: `Blades ${tag}` }).click();
		await page.getByLabel("Container").click();
		await page.getByRole("option", { name: `Rack ${tag}` }).click();
		await page.getByLabel("Size").click();
		await page.getByRole("option", { name: "Medium" }).click();
		await page.getByLabel("Notes").fill("Training loaner");
		await page.getByRole("button", { name: "Add item" }).click();

		// Creating an item navigates to its addressable management route.
		await expect(page).toHaveURL(/\/dashboard\/inventory\/items\/item-\d+$/);
		await expect(page.getByText("Medium").first()).toBeVisible();
		await expect(
			page.getByRole("tab", { name: "Details", selected: true }),
		).toBeVisible();
		await page.getByRole("link", { name: "All items" }).click();
		await expect(page).toHaveURL(/\/dashboard\/inventory\/items$/);

		const item = page.getByRole("article").filter({ hasText: "Medium" });
		await expect(item).toContainText("Training loaner");

		await page.getByRole("button", { name: "Filters", exact: true }).click();
		const filters = page.getByRole("dialog", {
			name: "Filter items",
		});
		await expect(filters).toBeVisible();
		await filters.getByRole("button", { name: "Availability" }).click();
		await page.getByRole("option", { name: "Maintenance" }).click();
		await filters.getByRole("button", { name: "Show items" }).click();
		await expect(
			page.getByRole("button", { name: "Filters, 1 active", exact: true }),
		).toBeVisible();

		await page
			.getByRole("button", { name: "Filters, 1 active", exact: true })
			.click();
		await page.getByRole("button", { name: "Clear filters" }).click();
		await page.getByRole("button", { name: "Show items" }).click();
		await expect(item).toBeVisible();

		await page.getByLabel("Search items").fill(`missing-${tag}`);
		await expect(
			page.getByRole("heading", { name: "No items found" }),
		).toBeVisible();

		const searched = page.waitForResponse((response) => {
			const url = new URL(response.url());
			return (
				url.pathname === "/api/inventory/items" &&
				url.searchParams.get("q") === "Training loaner"
			);
		});
		await page.getByLabel("Search items").fill("  Training loaner  ");
		await searched;
		await expect(item).toBeVisible();
		await item.getByRole("link", { name: "Manage" }).click();
		await expect(page).toHaveURL(/\/dashboard\/inventory\/items\/item-\d+$/);

		await page.getByRole("tab", { name: "Placement" }).click();
		await page.getByLabel("Move to container").click();
		await page.getByRole("option", { name: `Cupboard ${tag}` }).click();
		await page.getByRole("button", { name: "Move item" }).click();
		await expect(
			page.getByRole("button", { name: "Move to container" }),
		).toContainText(`Cupboard ${tag}`);

		await page.getByRole("tab", { name: "Maintenance" }).click();
		await page.getByLabel("Maintenance reason").fill("Inspect strap");
		await page.getByRole("button", { name: "Start maintenance" }).click();
		await expect(
			page.getByRole("button", { name: "End maintenance" }),
		).toBeVisible();
		await expect(page.getByText("Inspect strap")).toBeVisible();

		await page.getByLabel("Maintenance end note").fill("Strap secure");
		await page.getByRole("button", { name: "End maintenance" }).click();
		await expect(page.getByText("Strap secure")).toBeVisible();

		await page.getByRole("tab", { name: "Placement" }).click();
		await page.getByLabel("New category").click();
		await page.getByRole("option", { name: `Masks ${tag}` }).click();
		await page.getByLabel("Colour").fill("Black");
		// A lingering success toast can overlap the submit button, and a
		// cursor resting over it pauses its auto-dismiss timer: park the
		// cursor away from the toast region, then wait for toasts to clear
		// before clicking through.
		await page.mouse.move(5, 5);
		await expect(page.locator("[data-sonner-toast]")).toHaveCount(0, {
			timeout: 15_000,
		});
		await page.getByRole("button", { name: "Save category" }).click();
		await expect(
			page.getByRole("heading", { name: /Masks.*Black/ }).first(),
		).toBeVisible();

		await page.getByRole("tab", { name: "Details" }).click();
		await page.getByRole("button", { name: "Archive item" }).click();
		await expect(page.getByText("Archived", { exact: true })).toBeVisible();
		await page.getByRole("button", { name: "Restore item" }).click();
		await expect(page.getByText("Available", { exact: true })).toBeVisible();

		// No fixture cleanup: this lifecycle intentionally retains item, structure,
		// and actor references. The E2E run owns a disposable database.
	});
});
