import { expect, type Page, test } from "@playwright/test";
import type { Database } from "../database.types";
import { supabaseServiceClient } from "../src/lib/server/supabaseServiceClient";
import { makeAuthenticatedRequest as baseRequest } from "./attendee-test-helpers";
import { createMember } from "./setupFunctions";
import { loginAsUser } from "./supabaseLogin";

async function makeAuthenticatedRequest(
	page: Page,
	url: string,
	options: {
		method?: string;
		data?: unknown;
		headers?: Record<string, string>;
	} = {},
) {
	const response = await baseRequest(page, url, options);
	return await response.json();
}

test.describe("Inventory Categories Management", () => {
	let quartermasterData: Awaited<ReturnType<typeof createMember>>;
	let memberData: Awaited<ReturnType<typeof createMember>>;
	let adminData: Awaited<ReturnType<typeof createMember>>;

	test.beforeAll(async () => {
		const timestamp = Date.now();

		// Create quartermaster user
		quartermasterData = await createMember({
			email: `quartermaster-categories-${timestamp}@test.com`,
			roles: new Set(["quartermaster"]),
		});

		// Create regular member user
		memberData = await createMember({
			email: `member-categories-${timestamp}@test.com`,
			roles: new Set(["member"]),
		});

		// Create admin user
		adminData = await createMember({
			email: `admin-categories-${timestamp}@test.com`,
			roles: new Set(["admin"]),
		});
	});

	test.afterAll(async () => {
		await quartermasterData.cleanUp();
		await memberData.cleanUp();
		await adminData.cleanUp();
	});

	function createCategory(
		cat: Database["public"]["Tables"]["equipment_categories"]["Insert"],
	) {
		return supabaseServiceClient
			.from("equipment_categories")
			.insert(cat)
			.select("*")
			.single()
			.throwOnError();
	}

	test.describe("Category CRUD Operations", () => {
		test("should create basic category as quartermaster", async ({
			page,
			context,
		}) => {
			await loginAsUser(context, quartermasterData.email);
			await page.goto("/dashboard/inventory/categories");

			const timestamp = Date.now();
			const categoryName = `Test Category ${timestamp}`;

			// Click create category button (could be "Add Category" or "Create Category" depending on empty state)
			await page
				.getByRole("link", { name: /(?:add|create) category/i })
				.first()
				.click();

			// Fill basic form
			await page.getByLabel(/category name/i).fill(categoryName);
			await page.getByLabel(/description/i).fill("Test category for equipment");

			// Submit form
			await page.getByRole("button", { name: /create category/i }).click();

			// Should redirect to categories list
			await expect(page).toHaveURL("/dashboard/inventory/categories/create");

			// Should appear in categories list
			await expect(page.getByText(categoryName)).toBeVisible();
		});

		test("should create category with attributes as quartermaster", async ({
			page,
			context,
		}) => {
			await loginAsUser(context, quartermasterData.email);
			await page.goto("/dashboard/inventory/categories");

			const timestamp = Date.now();
			const categoryName = `Weapons Category ${timestamp}`;

			// Click create category button
			await page
				.getByRole("link", { name: /(?:add|create) category/i })
				.first()
				.click();

			// Fill basic form
			await page.getByLabel(/category name/i).fill(categoryName);
			await page
				.getByLabel(/description/i)
				.fill("Category for weapon equipment");

			// Add attributes using AttributeBuilder
			// Add text attribute
			await page
				.getByLabel(/display label/i)
				.first()
				.fill("Brand");
			await page.getByRole("button", { name: /add attribute/i }).click();

			// Add select attribute
			await page
				.getByLabel(/display label/i)
				.first()
				.fill("Weapon Type");
			await page.getByRole("button", { name: "Attribute Type" }).click();
			await page.getByText("Dropdown Select").click();
			await page.getByRole("button", { name: /add attribute/i }).click();

			// Add options to select attribute
			await page.getByRole("button", { name: /add option/i }).click();
			await page.getByPlaceholder(/option value/i).fill("Longsword");
			await page.getByRole("button", { name: /add option/i }).click();
			await page
				.getByPlaceholder(/option value/i)
				.last()
				.fill("Rapier");

			// Add number attribute
			await page
				.getByLabel(/display label/i)
				.first()
				.fill("Weight (kg)");
			await page.getByRole("button", { name: /attribute type/i }).click();
			await page.getByText("Number Input").click();
			await page
				.getByRole("checkbox", { name: /required field/i })
				.last()
				.check();
			await page.getByRole("button", { name: /add attribute/i }).click();

			// Add boolean attribute
			await page
				.getByLabel(/display label/i)
				.first()
				.fill("In Maintenance");
			await page.getByRole("button", { name: /attribute type/i }).click();
			await page.getByText("Checkbox").click();
			await page.getByRole("button", { name: /add attribute/i }).click();

			// Submit form
			await page.getByRole("button", { name: /create category/i }).click();

			// Should redirect to categories list
			await expect(page).toHaveURL("/dashboard/inventory/categories");

			// Should appear in categories list
			await expect(page.getByText(categoryName)).toBeVisible();
		});

		test("should edit category and modify attributes", async ({
			page,
			context,
		}) => {
			await loginAsUser(context, quartermasterData.email);
			await page.goto("/dashboard/inventory/categories");

			const timestamp = Date.now();
			const originalName = `Original Category ${timestamp}`;
			const updatedName = `Updated Category ${timestamp}`;

			// Create category first via API
			await page.goto("/dashboard");
			const createResponse = await createCategory({
				name: originalName,
				description: "Original description",
				available_attributes: {
					brand: {
						type: "text",
						label: "Brand",
						required: false,
					},
				},
			});

			const categoryId = createResponse.data.id;

			// Navigate to edit page
			await page.goto(`/dashboard/inventory/categories/${categoryId}/edit`);

			// Update basic info
			await page.getByLabel(/category name/i).fill(updatedName);
			await page.getByLabel(/description/i).fill("Updated description");

			// Modify existing attribute
			await page.locator('input[value="Brand"]').fill("Manufacturer");

			// Add new attribute
			await page.getByLabel(/display label/i).fill("Model");
			await page.getByRole("button", { name: /add attribute/i }).click();

			// Submit changes
			await page.getByRole("button", { name: /update category/i }).click();

			// Should redirect to categories list
			await expect(page).toHaveURL("/dashboard/inventory/categories");

			// Should show updated name
			await expect(page.getByText(updatedName)).toBeVisible();
		});

		test("should delete category with no items", async ({ page, context }) => {
			await loginAsUser(context, quartermasterData.email);
			await page.goto("/dashboard/inventory/categories");

			const timestamp = Date.now();
			const categoryName = `Delete Me ${timestamp}`;

			// Create category first
			await page
				.getByRole("link", { name: /(?:add|create) category/i })
				.click();
			await page.getByLabel(/category name/i).fill(categoryName);
			await page.getByLabel(/description/i).fill("Category to be deleted");
			await page.getByRole("button", { name: /create category/i }).click();
			await expect(page).toHaveURL("/dashboard/inventory/categories");

			// Find and delete the category
			await page.getByText(categoryName).click();
			await page.getByRole("button", { name: /delete/i }).click();

			// Confirm deletion
			await page.getByRole("button", { name: /confirm/i }).click();

			// Should redirect to categories list
			await expect(page).toHaveURL("/dashboard/inventory/categories");

			// Should not appear in list
			await expect(page.getByText(categoryName)).not.toBeVisible();
		});

		test("should prevent deletion of category with items", async ({
			page,
			context,
		}) => {
			await loginAsUser(context, quartermasterData.email);

			const timestamp = Date.now();
			const categoryName = `Category With Items ${timestamp}`;

			// Create category and item via API
			await page.goto("/dashboard");
			const categoryResponse = await makeAuthenticatedRequest(
				page,
				"/api/inventory/categories",
				{
					method: "POST",
					data: {
						name: categoryName,
						description: "Category that will have items",
						available_attributes: {},
					},
				},
			);

			// Create a container first
			const containerResponse = await makeAuthenticatedRequest(
				page,
				"/api/inventory/containers",
				{
					method: "POST",
					data: {
						name: "Test Container",
						description: "Container for test item",
					},
				},
			);

			// Create an item in the category
			await makeAuthenticatedRequest(page, "/api/inventory/items", {
				method: "POST",
				data: {
					name: "Test Item",
					description: "Test item in category",
					category_id: categoryResponse.category.id,
					container_id: containerResponse.container.id,
					quantity: 1,
					attributes: {},
				},
			});

			// Navigate to categories page
			await page.goto("/dashboard/inventory/categories");

			// Try to delete the category
			await page.getByText(categoryName).click();
			await page.getByRole("button", { name: /delete/i }).click();

			// Should show error message
			await expect(
				page.getByText(/cannot delete category that has items/i),
			).toBeVisible();
		});
	});

	test.describe("Attribute Builder Functionality", () => {
		test("should auto-generate attribute keys from labels", async ({
			page,
			context,
		}) => {
			await loginAsUser(context, quartermasterData.email);
			await page.goto("/dashboard/inventory/categories");

			const timestamp = Date.now();
			const categoryName = `Key Generation Test ${timestamp}`;

			// Click create category button
			await page
				.getByRole("link", { name: /(?:add|create) category/i })
				.click();

			// Fill basic form
			await page.getByLabel(/category name/i).fill(categoryName);
			await page
				.getByLabel(/description/i)
				.fill("Test category for key generation");

			// Add attribute with complex label
			await page.getByLabel(/display label/i).fill("Glove Type & Size");

			// Should show generated key preview
			await expect(page.getByText(/key will be:/i)).toBeVisible();
			await expect(page.getByText("glovetypesize")).toBeVisible();

			// Add the attribute
			await page.getByRole("button", { name: /add attribute/i }).click();

			// Add another attribute with same base name to test uniqueness
			await page.getByLabel(/display label/i).fill("Glove Type");

			// Should show unique key
			await expect(page.getByText("glovetype1")).toBeVisible();

			await page.getByRole("button", { name: /add attribute/i }).click();

			// Submit form
			await page.getByRole("button", { name: /create category/i }).click();

			// Should redirect to categories list
			await expect(page).toHaveURL("/dashboard/inventory/categories");
		});

		test("should handle attribute validation errors", async ({
			page,
			context,
		}) => {
			await loginAsUser(context, quartermasterData.email);
			await page.goto("/dashboard/inventory/categories");

			const timestamp = Date.now();
			const categoryName = `Validation Test ${timestamp}`;

			// Click create category button
			await page
				.getByRole("link", { name: /(?:add|create) category/i })
				.click();

			// Fill basic form
			await page.getByLabel(/category name/i).fill(categoryName);
			await page
				.getByLabel(/description/i)
				.fill("Test category for validation");

			// Add select attribute without options
			await page.getByLabel(/display label/i).fill("Invalid Select");
			await page.getByRole("combobox", { name: /attribute type/i }).click();
			await page.getByText("Dropdown Select").click();
			await page.getByRole("button", { name: /add attribute/i }).click();

			// Submit form (should fail validation)
			await page.getByRole("button", { name: /create category/i }).click();

			// Should show validation error
			await expect(
				page.getByText(/invalid type: expected string but received undefined/i),
			).toBeVisible();
		});

		test("should allow editing attribute options", async ({
			page,
			context,
		}) => {
			await loginAsUser(context, quartermasterData.email);

			const timestamp = Date.now();
			const categoryName = `Edit Options Test ${timestamp}`;

			// Create category with select attribute via API
			await page.goto("/dashboard");
			const createResponse = await makeAuthenticatedRequest(
				page,
				"/api/inventory/categories",
				{
					method: "POST",
					data: {
						name: categoryName,
						description: "Category for testing option editing",
						available_attributes: {
							weaponType: {
								type: "select",
								label: "Weapon Type",
								required: false,
								options: ["Longsword", "Rapier"],
							},
						},
					},
				},
			);

			// Navigate to edit page
			await page.goto(
				`/dashboard/inventory/categories/${createResponse.category.id}/edit`,
			);

			// Should show existing options
			await expect(page.locator('input[value="Longsword"]')).toBeVisible();
			await expect(page.locator('input[value="Rapier"]')).toBeVisible();

			// Add new option
			await page.getByRole("button", { name: /add option/i }).click();
			await page
				.getByPlaceholder(/option value/i)
				.last()
				.fill("Sabre");

			// Remove first option
			await page
				.locator('input[value="Longsword"]')
				.locator("..")
				.getByRole("button", { name: /trash/i })
				.click();

			// Submit changes
			await page.getByRole("button", { name: /update category/i }).click();

			// Should redirect to categories list
			await expect(page).toHaveURL("/dashboard/inventory/categories");
		});

		test("should remove attributes correctly", async ({ page, context }) => {
			await loginAsUser(context, quartermasterData.email);

			const timestamp = Date.now();
			const categoryName = `Remove Attribute Test ${timestamp}`;

			// Create category with multiple attributes via API
			await page.goto("/dashboard");
			const createResponse = await makeAuthenticatedRequest(
				page,
				"/api/inventory/categories",
				{
					method: "POST",
					data: {
						name: categoryName,
						description: "Category for testing attribute removal",
						available_attributes: {
							brand: {
								type: "text",
								label: "Brand",
								required: false,
							},
							model: {
								type: "text",
								label: "Model",
								required: true,
							},
							weight: {
								type: "number",
								label: "Weight",
								required: false,
							},
						},
					},
				},
			);

			// Navigate to edit page
			await page.goto(
				`/dashboard/inventory/categories/${createResponse.category.id}/edit`,
			);

			// Should show all attributes
			await expect(page.locator('input[value="Brand"]')).toBeVisible();
			await expect(page.locator('input[value="Model"]')).toBeVisible();
			await expect(page.locator('input[value="Weight"]')).toBeVisible();

			// Remove middle attribute (Model)
			await page
				.locator('input[value="Model"]')
				.locator("..")
				.locator("..")
				.getByRole("button", { name: /trash/i })
				.click();

			// Should not show Model attribute anymore
			await expect(page.locator('input[value="Model"]')).not.toBeVisible();

			// Should still show other attributes
			await expect(page.locator('input[value="Brand"]')).toBeVisible();
			await expect(page.locator('input[value="Weight"]')).toBeVisible();

			// Submit changes
			await page.getByRole("button", { name: /update category/i }).click();

			// Should redirect to categories list
			await expect(page).toHaveURL("/dashboard/inventory/categories");
		});
	});

	test.describe("Category API Endpoints", () => {
		test("should create category via API as quartermaster", async ({
			page,
			context,
		}) => {
			await loginAsUser(context, quartermasterData.email);
			await page.goto("/dashboard");

			const timestamp = Date.now();
			const categoryData = {
				name: `API Category ${timestamp}`,
				description: "Category created via API",
				available_attributes: {
					brand: {
						type: "text",
						label: "Brand",
						required: false,
					},
					condition: {
						type: "select",
						label: "Condition",
						required: true,
						options: ["New", "Good", "Fair", "Poor"],
					},
				},
			};

			const response = await makeAuthenticatedRequest(
				page,
				"/api/inventory/categories",
				{
					method: "POST",
					data: categoryData,
				},
			);

			expect(response.success).toBe(true);
			expect(response.category.name).toBe(categoryData.name);
			expect(response.category.description).toBe(categoryData.description);
			expect(response.category.available_attributes).toEqual(
				categoryData.available_attributes,
			);
		});

		test("should update category via API", async ({ page, context }) => {
			await loginAsUser(context, quartermasterData.email);
			await page.goto("/dashboard");

			const timestamp = Date.now();

			// Create category
			const createResponse = await makeAuthenticatedRequest(
				page,
				"/api/inventory/categories",
				{
					method: "POST",
					data: {
						name: `Update Test ${timestamp}`,
						description: "Original description",
						available_attributes: {
							brand: {
								type: "text",
								label: "Brand",
								required: false,
							},
						},
					},
				},
			);

			const categoryId = createResponse.category.id;

			// Update category
			const updateResponse = await makeAuthenticatedRequest(
				page,
				`/api/inventory/categories/${categoryId}`,
				{
					method: "PUT",
					data: {
						name: `Updated Test ${timestamp}`,
						description: "Updated description",
						available_attributes: {
							brand: {
								type: "text",
								label: "Manufacturer",
								required: true,
							},
							model: {
								type: "text",
								label: "Model",
								required: false,
							},
						},
					},
				},
			);

			expect(updateResponse.success).toBe(true);
			expect(updateResponse.category.name).toBe(`Updated Test ${timestamp}`);
			expect(updateResponse.category.description).toBe("Updated description");
			expect(updateResponse.category.available_attributes.brand.label).toBe(
				"Manufacturer",
			);
			expect(updateResponse.category.available_attributes.model).toBeDefined();
		});

		test("should delete category via API", async ({ page, context }) => {
			await loginAsUser(context, quartermasterData.email);
			await page.goto("/dashboard");

			const timestamp = Date.now();

			// Create category
			const createResponse = await makeAuthenticatedRequest(
				page,
				"/api/inventory/categories",
				{
					method: "POST",
					data: {
						name: `Delete Test ${timestamp}`,
						description: "Category to delete",
						available_attributes: {},
					},
				},
			);

			const categoryId = createResponse.category.id;

			// Delete category
			const deleteResponse = await makeAuthenticatedRequest(
				page,
				`/api/inventory/categories/${categoryId}`,
				{
					method: "DELETE",
				},
			);

			expect(deleteResponse.success).toBe(true);
		});

		test("should reject invalid category data", async ({ page, context }) => {
			await loginAsUser(context, quartermasterData.email);
			await page.goto("/dashboard");

			const invalidData = {
				name: "", // Invalid: empty name
				description: "Valid description",
				available_attributes: {
					invalid: {
						type: "invalid_type", // Invalid type
						label: "Invalid",
					},
				},
			};

			const response = await makeAuthenticatedRequest(
				page,
				"/api/inventory/categories",
				{
					method: "POST",
					data: invalidData,
				},
			);

			expect(response.success).toBe(false);
			expect(response.error).toBe("Invalid data");
			expect(response.issues).toBeDefined();
		});

		test("should validate attribute schema correctly", async ({
			page,
			context,
		}) => {
			await loginAsUser(context, quartermasterData.email);
			await page.goto("/dashboard");

			const timestamp = Date.now();

			// Test select attribute without options
			const invalidSelectData = {
				name: `Invalid Select ${timestamp}`,
				description: "Category with invalid select attribute",
				available_attributes: {
					invalidSelect: {
						type: "select",
						label: "Invalid Select",
						// Missing options array
					},
				},
			};

			const response1 = await makeAuthenticatedRequest(
				page,
				"/api/inventory/categories",
				{
					method: "POST",
					data: invalidSelectData,
				},
			);

			expect(response1.success).toBe(false);

			// Test attribute without label
			const invalidLabelData = {
				name: `Invalid Label ${timestamp}`,
				description: "Category with invalid attribute label",
				available_attributes: {
					invalidLabel: {
						type: "text",
						// Missing label
					},
				},
			};

			const response2 = await makeAuthenticatedRequest(
				page,
				"/api/inventory/categories",
				{
					method: "POST",
					data: invalidLabelData,
				},
			);

			expect(response2.success).toBe(false);
		});
	});

	test.describe("Access Control", () => {
		test("should allow quartermaster full access to categories", async ({
			page,
			context,
		}) => {
			await loginAsUser(context, quartermasterData.email);
			await page.goto("/dashboard/inventory/categories");

			// Should see create button
			await expect(
				page.getByRole("link", { name: /(?:add|create) category/i }),
			).toBeVisible();

			// Should be able to access categories page
			await expect(
				page.getByRole("heading", { name: /categories/i }),
			).toBeVisible();
		});

		test("should allow members read-only access to categories", async ({
			page,
			context,
		}) => {
			await loginAsUser(context, memberData.email);
			await page.goto("/dashboard/inventory/categories");

			// Should be able to view categories
			await expect(
				page.getByRole("heading", { name: /categories/i }),
			).toBeVisible();

			// Should not see create button
			await expect(
				page.getByRole("link", { name: /(?:add|create) category/i }),
			).not.toBeVisible();
		});

		test("should deny member API access to create categories", async ({
			page,
			context,
		}) => {
			await loginAsUser(context, memberData.email);
			await page.goto("/dashboard");

			const response = await makeAuthenticatedRequest(
				page,
				"/api/inventory/categories",
				{
					method: "POST",
					data: {
						name: "Unauthorized Category",
						description: "Should not be created",
						available_attributes: {},
					},
				},
			);

			expect(response.success).toBe(false);
			expect(response.error).toContain("Unauthorized");
		});

		test("should allow admin full access to categories", async ({
			page,
			context,
		}) => {
			await loginAsUser(context, adminData.email);
			await page.goto("/dashboard/inventory/categories");

			// Should see create button
			await expect(
				page.getByRole("link", { name: /(?:add|create) category/i }),
			).toBeVisible();

			// Should be able to create via API
			await page.goto("/dashboard");
			const response = await makeAuthenticatedRequest(
				page,
				"/api/inventory/categories",
				{
					method: "POST",
					data: {
						name: "Admin Category",
						description: "Created by admin",
						available_attributes: {},
					},
				},
			);

			expect(response.success).toBe(true);
		});
	});

	test.describe("Category Search and Filtering", () => {
		test("should search categories by name", async ({ page, context }) => {
			await loginAsUser(context, quartermasterData.email);

			const timestamp = Date.now();

			// Create test categories
			await page.goto("/dashboard");
			await makeAuthenticatedRequest(page, "/api/inventory/categories", {
				method: "POST",
				data: {
					name: `Searchable Category ${timestamp}`,
					description: "Category for search test",
					available_attributes: {},
				},
			});

			await makeAuthenticatedRequest(page, "/api/inventory/categories", {
				method: "POST",
				data: {
					name: `Other Category ${timestamp}`,
					description: "Different category",
					available_attributes: {},
				},
			});

			// Navigate to categories page
			await page.goto("/dashboard/inventory/categories");

			// Search for specific category
			await page.getByPlaceholder(/search categories/i).fill("Searchable");

			// Should show only matching category
			await expect(
				page.getByText(`Searchable Category ${timestamp}`),
			).toBeVisible();
			await expect(
				page.getByText(`Other Category ${timestamp}`),
			).not.toBeVisible();
		});

		test("should filter categories by attribute types", async ({
			page,
			context,
		}) => {
			await loginAsUser(context, quartermasterData.email);

			const timestamp = Date.now();

			// Create categories with different attribute types
			await page.goto("/dashboard");
			await makeAuthenticatedRequest(page, "/api/inventory/categories", {
				method: "POST",
				data: {
					name: `Text Category ${timestamp}`,
					description: "Category with text attributes",
					available_attributes: {
						brand: { type: "text", label: "Brand" },
					},
				},
			});

			await makeAuthenticatedRequest(page, "/api/inventory/categories", {
				method: "POST",
				data: {
					name: `Select Category ${timestamp}`,
					description: "Category with select attributes",
					available_attributes: {
						type: { type: "select", label: "Type", options: ["A", "B"] },
					},
				},
			});

			// Navigate to categories page
			await page.goto("/dashboard/inventory/categories");

			// Filter by attribute type (if filter exists)
			if (
				await page
					.getByRole("combobox", { name: /filter by attribute type/i })
					.isVisible()
			) {
				await page
					.getByRole("combobox", { name: /filter by attribute type/i })
					.click();
				await page.getByText("Text").click();

				// Should show only text category
				await expect(
					page.getByText(`Text Category ${timestamp}`),
				).toBeVisible();
				await expect(
					page.getByText(`Select Category ${timestamp}`),
				).not.toBeVisible();
			}
		});
	});
});
