import { expect, test } from '@playwright/test';
import { createMember, getSupabaseServiceClient } from './setupFunctions';
import { loginAsUser } from './supabaseLogin';

test.describe('Inventory Containers Management', () => {
	let quartermasterData: Awaited<ReturnType<typeof createMember>>;
	let memberData: Awaited<ReturnType<typeof createMember>>;
	let adminData: Awaited<ReturnType<typeof createMember>>;

	test.beforeAll(async () => {
		const timestamp = Date.now();

		// Create quartermaster user
		quartermasterData = await createMember({
			email: `quartermaster-containers-${timestamp}@test.com`,
			roles: new Set(['quartermaster'])
		});

		// Create regular member user
		memberData = await createMember({
			email: `member-containers-${timestamp}@test.com`,
			roles: new Set(['member'])
		});

		// Create admin user
		adminData = await createMember({
			email: `admin-containers-${timestamp}@test.com`,
			roles: new Set(['admin'])
		});
	});

	test.afterAll(async () => {
		await quartermasterData.cleanUp();
		await memberData.cleanUp();
		await adminData.cleanUp();
	});

	async function makeAuthenticatedRequest(page: any, url: string, options: any = {}) {
		const response = await page.request.fetch(url, {
			...options,
			headers: {
				'Content-Type': 'application/json',
				...options.headers
			}
		});
		return await response.json();
	}

	async function createContainer(
		{
			createItems = false,
			parentId = null
		}: {
			createItems?: boolean;
			parentId?: string | null;
		} = { createItems: false, parentId: null }
	) {
		const timestamp = Date.now();
		const containerName = `Container With Items ${timestamp}`;

		// Create container directly using Supabase service client
		const supabaseServiceClient = getSupabaseServiceClient();

		// Create container
		const { data: containerData, error: containerError } = await supabaseServiceClient
			.from('containers')
			.insert({
				name: containerName,
				description: 'Container that will have items',
				created_by: quartermasterData.userId!,
				parent_container_id: parentId
			})
			.select()
			.single();

		expect(containerError).toBeNull();
		expect(containerData).toBeTruthy();

		if (createItems) {
			const containerId = containerData!.id;
			// Create a category
			const { data: categoryData, error: categoryError } = await supabaseServiceClient
				.from('equipment_categories')
				.insert({
					name: `Test Category ${timestamp}`,
					description: 'Test category for items',
					available_attributes: {}
				})
				.select()
				.single();

			expect(categoryError).toBeNull();
			expect(categoryData).toBeTruthy();

			// Create an item in the container
			const { error: itemError } = await supabaseServiceClient.from('inventory_items').insert({
				category_id: categoryData!.id,
				container_id: containerId,
				quantity: 1,
				attributes: {},
				created_by: quartermasterData.userId
			});

			expect(itemError).toBeNull();
		}
		return containerData;
	}

	test.describe('Container CRUD Operations', () => {
		test('should create root container as quartermaster', async ({ page, context }) => {
			await loginAsUser(context, quartermasterData.email);
			await page.goto('/dashboard/inventory/containers');
			const timestamp = Date.now();
			const containerName = `Test Room ${timestamp}`;

			// Click create container button
			await page.getByRole('link', { name: 'Add Container' }).nth(1).click();

			// Fill form
			await page.getByLabel(/name/i).fill(containerName);
			await page.getByLabel(/description/i).fill('Test room for equipment storage');
			// Submit form
			await page.getByRole('button', { name: /create/i }).click();

			// Should navigate to container view page
			await expect(page).toHaveURL(/\/dashboard\/inventory\/containers\/[^/]+$/);

			// Should show container name on the view page
			await expect(page.getByText(containerName).first()).toBeVisible();
		});

		test('should create nested container as quartermaster', async ({ page, context }) => {
			await loginAsUser(context, quartermasterData.email);
			await page.goto('/dashboard/inventory/containers');

			const timestamp = Date.now();
			const { name: parentName } = await createContainer();
			const childName = `Child Container ${timestamp}`;
			// Go back to containers list
			await page.goto('/dashboard/inventory/containers');

			// Create child container
			await page.getByRole('link', { name: 'Add Container' }).nth(1).click();
			await page.getByLabel(/name/i).fill(childName);
			await page.getByLabel(/description/i).fill('Child container');
			// Select parent container
			await page.getByLabel(/parent container/i).click();
			await page.getByText(parentName).click();

			await page.getByRole('button', { name: /create/i }).click();

			// Should navigate to child container view
			await expect(page).toHaveURL(/\/dashboard\/inventory\/containers\/[^/]+$/);

			// Should show child container name
			await expect(page.getByText(childName).first()).toBeVisible();
		});

		test('should edit container as quartermaster', async ({ page, context }) => {
			await loginAsUser(context, quartermasterData.email);
			await page.goto('/dashboard/inventory/containers');

			const timestamp = Date.now();
			const originalName = await createContainer();
			const updatedName = `Updated Container ${timestamp}`;

			// Go back to containers list to find the container
			await page.goto('/dashboard/inventory/containers');

			// Find and edit the container
			await page.getByRole('link', { name: `Edit ${originalName}` }).click();

			// Update fields
			await page.getByLabel(/name/i).fill(updatedName);
			await page.getByLabel(/description/i).fill('Updated description');

			// Submit changes
			await page.getByRole('button', { name: /update/i }).click();
			// Should navigate back to container view or stay on edit page
			// Check if we're on the container view page with updated name
			await expect(page.getByText(updatedName).first()).toBeVisible();
		});

		test('should delete empty container as quartermaster', async ({ page, context }) => {
			await loginAsUser(context, quartermasterData.email);
			await page.goto('/dashboard/inventory/containers');

			const { name: containerName } = await createContainer();

			// Find and delete the container
			await page.getByRole('link', { name: `Edit ${containerName}`, exact: false }).click();
			await page.getByRole('button', { name: /delete/i }).click();

			// Confirm deletion
			await page.getByRole('button', { name: /yes, delete container/i }).click();

			// Should navigate back to containers list or show confirmation
			// Container should not appear in list anymore
			await expect(page.getByText(containerName)).not.toBeVisible();
		});

		test('should prevent deletion of container with items', async ({ page, context }) => {
			await loginAsUser(context, quartermasterData.email);

			const containerName = await createContainer({ createItems: true });

			// Navigate to containers page
			await page.goto('/dashboard/inventory/containers');

			// Try to delete the container
			await page.getByRole('link', { name: `Edit ${containerName}` }).click();
			await page.getByRole('button', { name: /delete/i }).click();

			// Confirm deletion
			await page.getByRole('button', { name: /yes, delete container/i }).click();

			// Should show error message
			await expect(page.getByText(/cannot delete a container that contains items/i)).toBeVisible();
		});
	});

	test.describe('Access Control', () => {
		test('should allow quartermaster full access to containers', async ({ page, context }) => {
			await loginAsUser(context, quartermasterData.email);
			await page.goto('/dashboard/inventory/containers');

			// Should see create button
			await expect(page.getByRole('link', { name: 'Add Container' }).first()).toBeVisible();

			// Should be able to access containers page
			await expect(page.getByRole('heading', { name: /containers/i }).first()).toBeVisible();
		});

		test('should allow members read-only access to containers', async ({ page, context }) => {
			await loginAsUser(context, memberData.email);
			await page.goto('/dashboard/inventory/containers');

			// Should be able to view containers
			await expect(page.getByRole('heading', { name: /containers/i }).first()).toBeVisible();

			// Should not see create button
			await expect(page.getByRole('link', { name: 'Add Container' })).not.toBeVisible();
		});

		test('should allow admin full access to containers', async ({ page, context }) => {
			await loginAsUser(context, adminData.email);
			await page.goto('/dashboard/inventory/containers');

			// Should see create button
			await expect(page.getByRole('link', { name: 'Add Container' }).first()).toBeVisible();

			// Should be able to create via API
			await page.goto('/dashboard');
			const data = await createContainer();

			expect(data).toBeTruthy();
		});
	});

	test.describe('Container Hierarchy Display', () => {
		test('should display container hierarchy correctly', async ({ page, context }) => {
			await loginAsUser(context, quartermasterData.email);

			// Create hierarchy via API
			await page.goto('/dashboard');
			const [c1, c2, c3] = await createContainer()
				.then(async (c) => [c, await createContainer({ parentId: c.id })])
				.then(async (c) => [...c, await createContainer({ parentId: c[1].id })]);

			// Navigate to containers page
			await page.goto('/dashboard/inventory/containers');

			// Should show hierarchy
			await expect(page.getByRole('heading', { name: c1.name })).toBeVisible();
			await expect(page.getByRole('heading', { name: c2.name })).toBeVisible();
			await expect(page.getByRole('heading', { name: c3.name })).toBeVisible();

			// Should show proper nesting indicators
			await expect(page.locator('[data-testid="container-hierarchy"]')).toBeVisible();
		});
	});
	// TODO: search functionality
	// TODO: embeddings
});
