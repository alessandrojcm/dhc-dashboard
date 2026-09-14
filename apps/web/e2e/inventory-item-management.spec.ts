import { expect, test } from "@playwright/test";
import { loginAsUser } from "./auth";
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
		const first = await createInventoryStructure({
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
		const second = await createInventoryStructure({
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

		try {
			await loginAsUser(context, operator.email);
			await page.goto("/dashboard/inventory/items");
			await expect(page.getByRole("heading", { name: "Items" })).toBeVisible();

			await page.getByLabel("Category").selectOption(first.categoryId);
			await page
				.getByLabel("Container")
				.selectOption(first.containerIds.at(-1));
			await page.getByLabel("Size").selectOption(first.optionIds[0]);
			await page.getByLabel("Notes").fill("Training loaner");
			await page.getByRole("button", { name: "Add item" }).click();

			const item = page.getByRole("article").filter({ hasText: "Medium" });
			await expect(item).toContainText("Training loaner");
			await item.getByRole("button", { name: "Manage" }).click();

			await page
				.getByLabel("Move to container")
				.selectOption(second.containerIds[0]);
			await page.getByRole("button", { name: "Move item" }).click();
			await expect(page.getByText(`Cupboard ${tag}`)).toBeVisible();

			await page.getByLabel("Maintenance reason").fill("Inspect strap");
			await page.getByRole("button", { name: "Start maintenance" }).click();
			await expect(
				page.getByRole("button", { name: "End maintenance" }),
			).toBeVisible();
			await expect(page.getByText("Inspect strap")).toBeVisible();

			await page.getByLabel("Maintenance end note").fill("Strap secure");
			await page.getByRole("button", { name: "End maintenance" }).click();
			await expect(page.getByText("Strap secure")).toBeVisible();

			await page.getByLabel("New category").selectOption(second.categoryId);
			await page.getByLabel("Colour").fill("Black");
			await page.getByRole("button", { name: "Change category" }).click();
			await expect(
				page.getByRole("heading", { name: /Masks.*Black/ }),
			).toBeVisible();

			await page.getByRole("button", { name: "Archive item" }).click();
			await expect(page.getByText("Archived", { exact: true })).toBeVisible();
			await page.getByRole("button", { name: "Restore item" }).click();
			await expect(page.getByText("Available", { exact: true })).toBeVisible();
		} finally {
			await second.cleanUp();
			await first.cleanUp();
			await operator.cleanUp();
		}
	});
});
