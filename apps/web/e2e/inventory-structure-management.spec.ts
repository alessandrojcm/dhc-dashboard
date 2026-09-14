import { expect, test } from "@playwright/test";
import { loginAsUser } from "./auth";
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
		try {
			await loginAsUser(context, operator.email);
			await page.goto("/dashboard/inventory/categories");
			await page.waitForLoadState("networkidle");
			await expect(
				page.getByRole("heading", { name: "Categories and properties" }),
			).toBeVisible();

			const categoryName = `E2E UI Category ${tag}`;
			await page.getByLabel("Name").fill(categoryName);
			await page
				.getByLabel("Description")
				.fill("Managed through the operator UI");
			const requestPromise = page.waitForRequest(
				(request) =>
					request.method() === "POST" &&
					request.url().endsWith("/api/inventory/categories"),
				{ timeout: 5_000 },
			);
			await page.getByRole("button", { name: "Add category" }).click();
			const request = await requestPromise;
			const response = await request.response();
			expect(response).not.toBeNull();
			expect(
				response!.status(),
				`category create response: ${await response!.text()}`,
			).toBe(201);
			const categoryButton = page.getByRole("button", {
				name: `${categoryName} 0 items`,
			});
			await expect(categoryButton).toBeVisible();
			await categoryButton.click();
			await page.getByRole("button", { name: "Edit" }).first().click();
			await expect(page.getByLabel("Name")).toHaveValue(categoryName);
			await expect(page.getByRole("button", { name: "Save" })).toBeVisible();

			await page.getByLabel("Label").fill("Size");
			await page.getByLabel("Value type").selectOption("single_select");
			await page.getByLabel("Identifying position").fill("0");
			await page.getByText("Required", { exact: true }).click();
			await page.getByRole("button", { name: "Add property" }).click();
			await expect(page.getByRole("heading", { name: "Size" })).toBeVisible();

			await page.getByLabel("New option label").fill("Medium");
			const optionResponsePromise = page.waitForResponse(
				(response) =>
					response.request().method() === "POST" &&
					response.url().includes("/options"),
			);
			await page.getByRole("button", { name: "Add", exact: true }).click();
			const optionResponse = await optionResponsePromise;
			expect(
				optionResponse.status(),
				`option create response: ${await optionResponse.text()}`,
			).toBe(201);
			await expect(page.getByLabel("Medium label")).toHaveValue("Medium");
		} finally {
			await operator.cleanUp();
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
			await page.goto("/dashboard/inventory/containers");
			await page
				.getByRole("article")
				.filter({ hasText: `E2E Child ${tag}` })
				.getByRole("button", { name: "Edit / move" })
				.click();
			await page.getByLabel("Parent").selectOption("");
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
			await structure.cleanUp();
			await member.cleanUp();
			await operator.cleanUp();
		}
	});
});
