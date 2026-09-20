import { expect, test } from "@playwright/test";
import { loginAsUser } from "./auth";
import { deleteE2EFixture } from "./e2eApi";
import {
	createInventoryStructure,
	createMember,
	createUniqueEmail,
} from "./setupFunctions";

const tag = `structure-ui-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;

test.describe("ALE-283 operator inventory structure", () => {
	test("operator creates and evolves categories, definitions, and options", async ({
		page,
		context,
	}) => {
		const operator = await createMember({
			email: createUniqueEmail("inventory-structure-operator"),
			roles: new Set(["member", "quartermaster"]),
		});
		let categoryId: string | undefined;
		try {
			await loginAsUser(context, operator.email);
			await page.setViewportSize({ width: 390, height: 844 });
			await page.goto("/dashboard/inventory/categories");
			await page.waitForLoadState("networkidle");
			await expect(
				page.getByRole("heading", { name: "Categories and properties" }),
			).toBeVisible();

			const categoryName = `E2E UI Category ${tag}`;
			await page.getByRole("button", { name: "New category" }).click();
			await page.getByLabel("Name").fill(categoryName);
			await page
				.getByLabel("Description")
				.fill("Managed through the operator UI");
			await page.getByRole("button", { name: "Add category" }).click();
			await expect(page.getByText("Category created")).toBeVisible();
			const categoryLink = page.getByRole("link", {
				name: `${categoryName} 0 items`,
			});
			await expect(categoryLink).toBeVisible();
			const categoryHref = await categoryLink.getAttribute("href");
			expect(categoryHref).not.toBeNull();
			categoryId = categoryHref!.split("/").pop();
			expect(categoryId).toBeTruthy();
			await categoryLink.click();
			await expect(page).toHaveURL(
				new RegExp(`/dashboard/inventory/categories/${categoryId!}$`),
			);
			await expect(
				page.getByRole("link", { name: "All categories" }),
			).toBeVisible();
			const breadcrumb = page.getByRole("navigation", { name: "breadcrumb" });
			await expect(breadcrumb).toContainText(categoryName);
			await expect(breadcrumb).not.toContainText(categoryId!);
			await expect(categoryLink).toBeHidden();
			await page.getByRole("button", { name: "Edit category" }).click();
			await expect(page.getByLabel("Name")).toHaveValue(categoryName);
			await expect(page.getByRole("button", { name: "Save" })).toBeVisible();
			await page.getByRole("button", { name: "Cancel" }).click();

			await page.getByRole("button", { name: "Add property" }).click();
			await page.getByLabel("Label", { exact: true }).fill("Size");
			await page.getByLabel("Value type").click();
			await page.getByRole("option", { name: "Single select" }).click();
			await page.getByLabel("Label position").fill("0");
			await page.getByText("Required", { exact: true }).click();
			await page
				.locator("form")
				.getByRole("button", { name: "Add property" })
				.click();
			await expect(page.getByRole("heading", { name: "Size" })).toBeVisible();
			const propertyCard = page
				.getByRole("article")
				.filter({ has: page.getByRole("heading", { name: "Size" }) });
			await expect(propertyCard).toContainText("Property 1 of 1");
			await propertyCard
				.getByRole("button", { name: "Property actions for Size" })
				.click();
			await expect(
				page.getByRole("menuitem", { name: "Edit property" }),
			).toBeVisible();
			await page.keyboard.press("Escape");

			await page.getByLabel("New option label").fill("Medium");
			await page.getByRole("button", { name: "Add", exact: true }).click();
			await expect(page.getByText("Option created")).toBeVisible();
			await expect(page.getByText("Medium", { exact: true })).toBeVisible();
		} finally {
			if (categoryId) {
				try {
					await deleteE2EFixture("inventoryStructure", categoryId);
				} catch {
					/* best-effort: per-run database is disposable */
				}
			}
			try {
				await operator.cleanUp();
			} catch {
				/* best-effort: per-run database is disposable */
			}
		}
	});

	test("operator moves a container while members cannot open the management UI", async ({
		page,
		context,
	}) => {
		const operator = await createMember({
			email: createUniqueEmail("inventory-container-operator"),
			roles: new Set(["member", "quartermaster"]),
		});
		const member = await createMember({
			email: createUniqueEmail("inventory-container-member"),
		});
		const structure = await createInventoryStructure({
			categoryName: `E2E Container Category ${tag}`,
			containerPath: [`E2E Root ${tag}`, `E2E Child ${tag}`],
			operatorActorId: operator.memberId,
		});
		try {
			await loginAsUser(context, operator.email);
			await page.setViewportSize({ width: 390, height: 844 });
			await page.goto("/dashboard/inventory/containers");
			await page.waitForLoadState("networkidle");
			const mobileHeader = page.locator("header").filter({
				has: page.getByRole("heading", { name: "Containers" }),
			});
			await expect(mobileHeader).toHaveCSS("position", "sticky");
			const newLocation = page.getByRole("button", { name: "New location" });
			await newLocation.click();
			const editor = page.getByRole("dialog");
			await expect(
				editor.getByRole("heading", { name: "Add container" }),
			).toBeVisible();
			await editor.getByRole("button", { name: "Cancel" }).click();
			await expect(editor).toBeHidden();
			await expect(newLocation).toBeFocused();
			await page
				.getByRole("article")
				.filter({ hasText: `E2E Child ${tag}` })
				.getByRole("button", { name: "Edit / move" })
				.click();
			await expect(
				editor.getByRole("heading", { name: "Edit container" }),
			).toBeVisible();
			await page.getByRole("button", { name: "Parent" }).click();
			await page.getByRole("option", { name: "Root", exact: true }).click();
			await page.getByRole("button", { name: "Save changes" }).click();
			await expect(page.getByText("Container updated")).toBeVisible();
			await expect(
				page
					.getByRole("article")
					.filter({ hasText: `E2E Child ${tag}` })
					.getByText("Root container"),
			).toBeVisible();

			await loginAsUser(context, member.email);
			await page.goto("/dashboard/inventory/categories");
			await expect(page).toHaveURL(/\/dashboard\/members\/[^/]+$/);
			await expect(
				page.getByRole("heading", { name: "My profile" }),
			).toBeVisible();
		} finally {
			for (const cleanUp of [
				() => structure.cleanUp(),
				() => member.cleanUp(),
				() => operator.cleanUp(),
			]) {
				try {
					await cleanUp();
				} catch {
					/* best-effort: per-run database is disposable */
				}
			}
		}
	});
});
