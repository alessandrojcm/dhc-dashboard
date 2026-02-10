import { expect, type Page, test } from "@playwright/test";
import { createMember } from "../setupFunctions";
import { loginAsUser } from "../supabaseLogin";

test.describe("Workshop API", () => {
	let adminData: Awaited<ReturnType<typeof createMember>>;
	let workshopCoordinatorData: Awaited<ReturnType<typeof createMember>>;

	test.beforeAll(async () => {
		const timestamp = Date.now();

		// Create admin user
		adminData = await createMember({
			email: `admin-${timestamp}@test.com`,
			roles: new Set(["admin"]),
		});

		// Create workshop coordinator user
		workshopCoordinatorData = await createMember({
			email: `coordinator-${timestamp}@test.com`,
			roles: new Set(["workshop_coordinator"]),
		});
	});

	async function makeAuthenticatedRequest(
		page: Page,
		url: string,
		options: {
			data?: Record<string, unknown>;
			headers?: Record<string, string>;
			method?: string;
		} = {
			headers: {},
			data: {},
			method: "GET",
		},
	) {
		const response = await page.request.fetch(url, {
			...options,
			headers: {
				"Content-Type": "application/json",
				...options.headers,
			},
		});
		return await response.json();
	}

	test("should create workshop as admin", async ({ page, context }) => {
		await loginAsUser(context, adminData.email);
		await page.goto("/dashboard");

		const timestamp = Date.now();

		const workshopData = {
			title: `Test Workshop ${timestamp}`,
			description: "Test description",
			location: "Test location",
			workshop_date: new Date(Date.now() + 86400000).toISOString(),
			workshop_time: "14:00",
			max_capacity: 10,
			price_member: 10,
			price_non_member: 20,
			is_public: true,
			refund_deadline_days: 3,
		};

		const response = await makeAuthenticatedRequest(page, "/api/workshops", {
			method: "POST",
			data: workshopData,
		});

		if (!response.success) {
			console.error("Admin API Error:", response);
		}
		expect(response.success).toBe(true);
		expect(response.workshop.title).toBe(workshopData.title);
		expect(response.workshop.status).toBe("planned");
	});

	test("should create workshop as workshop coordinator", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, workshopCoordinatorData.email);
		await page.goto("/dashboard");

		const timestamp = Date.now();

		const workshopData = {
			title: `Coordinator Workshop ${timestamp}`,
			description: "Test description by coordinator",
			location: "Test location",
			workshop_date: new Date(Date.now() + 86400000).toISOString(),
			workshop_time: "15:30",
			max_capacity: 15,
			price_member: 15,
			price_non_member: 25,
			is_public: false,
			refund_deadline_days: null,
		};

		const response = await makeAuthenticatedRequest(page, "/api/workshops", {
			method: "POST",
			data: workshopData,
		});

		if (!response.success) {
			console.error("Workshop Coordinator API Error:", response);
		}
		expect(response.success).toBe(true);
		expect(response.workshop.title).toBe(workshopData.title);
		expect(response.workshop.status).toBe("planned");
	});

	test("should update workshop", async ({ page, context }) => {
		await loginAsUser(context, adminData.email);
		await page.goto("/dashboard");

		// Create workshop first
		const createResponse = await makeAuthenticatedRequest(
			page,
			"/api/workshops",
			{
				method: "POST",
				data: {
					title: "Original Title",
					description: "Original description",
					location: "Original location",
					workshop_date: new Date(Date.now() + 86400000).toISOString(),
					workshop_time: "10:00",
					max_capacity: 10,
					price_member: 10,
					price_non_member: 20,
					is_public: true,
					refund_deadline_days: 3,
				},
			},
		);

		const workshopId = createResponse.workshop.id;

		// Update workshop
		const updateResponse = await makeAuthenticatedRequest(
			page,
			`/api/workshops/${workshopId}`,
			{
				method: "PUT",
				data: {
					title: "Updated Title",
					description: "Updated description",
				},
			},
		);

		expect(updateResponse.success).toBe(true);
		expect(updateResponse.workshop.title).toBe("Updated Title");
		expect(updateResponse.workshop.description).toBe("Updated description");
	});

	test("should publish workshop", async ({ page, context }) => {
		await loginAsUser(context, adminData.email);
		await page.goto("/dashboard");

		// Create workshop first
		const createResponse = await makeAuthenticatedRequest(
			page,
			"/api/workshops",
			{
				method: "POST",
				data: {
					title: "Test Workshop to Publish",
					description: "Test description",
					location: "Test location",
					workshop_date: new Date(Date.now() + 86400000).toISOString(),
					workshop_time: "16:00",
					max_capacity: 10,
					price_member: 10,
					price_non_member: 20,
					is_public: true,
					refund_deadline_days: 3,
				},
			},
		);

		const workshopId = createResponse.workshop.id;

		// Publish workshop
		const publishResponse = await makeAuthenticatedRequest(
			page,
			`/api/workshops/${workshopId}/publish`,
			{
				method: "POST",
			},
		);

		expect(publishResponse.success).toBe(true);
		expect(publishResponse.workshop.status).toBe("published");
	});

	test("should cancel workshop", async ({ page, context }) => {
		await loginAsUser(context, adminData.email);
		await page.goto("/dashboard");

		// Create workshop first
		const createResponse = await makeAuthenticatedRequest(
			page,
			"/api/workshops",
			{
				method: "POST",
				data: {
					title: "Test Workshop to Cancel",
					description: "Test description",
					location: "Test location",
					workshop_date: new Date(Date.now() + 86400000).toISOString(),
					workshop_time: "11:30",
					max_capacity: 10,
					price_member: 10,
					price_non_member: 20,
					is_public: true,
					refund_deadline_days: 3,
				},
			},
		);

		const workshopId = createResponse.workshop.id;

		// Cancel workshop
		const cancelResponse = await makeAuthenticatedRequest(
			page,
			`/api/workshops/${workshopId}/cancel`,
			{
				method: "POST",
			},
		);

		expect(cancelResponse.success).toBe(true);
		expect(cancelResponse.workshop.status).toBe("cancelled");
	});

	test("should delete workshop", async ({ page, context }) => {
		await loginAsUser(context, adminData.email);
		await page.goto("/dashboard");

		// Create workshop first
		const createResponse = await makeAuthenticatedRequest(
			page,
			"/api/workshops",
			{
				method: "POST",
				data: {
					title: "Test Workshop to Delete",
					description: "Test description",
					location: "Test location",
					workshop_date: new Date(Date.now() + 86400000).toISOString(),
					workshop_time: "09:00",
					max_capacity: 10,
					price_member: 10,
					price_non_member: 20,
					is_public: true,
					refund_deadline_days: 3,
				},
			},
		);

		const workshopId = createResponse.workshop.id;

		// Delete workshop
		const deleteResponse = await makeAuthenticatedRequest(
			page,
			`/api/workshops/${workshopId}`,
			{
				method: "DELETE",
			},
		);

		expect(deleteResponse.success).toBe(true);
	});

	test("should reject invalid workshop data", async ({ page, context }) => {
		await loginAsUser(context, adminData.email);
		await page.goto("/dashboard");

		const invalidWorkshopData = {
			title: "", // Invalid: empty title
			location: "Test location",
			workshop_date: new Date(Date.now() + 86400000).toISOString(),
			workshop_time: "12:00",
			max_capacity: 0, // Invalid: zero capacity
			price_member: -1, // Invalid: negative price
			price_non_member: 20,
		};

		const response = await makeAuthenticatedRequest(page, "/api/workshops", {
			method: "POST",
			data: invalidWorkshopData,
		});

		expect(response.success).toBe(false);
		expect(response.error).toBe("Invalid data");
		expect(response.issues).toBeDefined();
	});
});
