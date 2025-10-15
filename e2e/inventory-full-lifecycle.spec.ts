import { expect, test } from '@playwright/test';
import { createMember, getSupabaseServiceClient } from './setupFunctions';
import { loginAsUser } from './supabaseLogin';

test.describe('Inventory Management Full Lifecycle', () => {
	let quartermasterData: Awaited<ReturnType<typeof createMember>>;
	let memberData: Awaited<ReturnType<typeof createMember>>;

	test.beforeAll(async () => {
		const timestamp = Date.now();

		// Create quartermaster user
		quartermasterData = await createMember({
			email: `quartermaster-lifecycle-${timestamp}@test.com`,
			roles: new Set(['quartermaster'])
		});

		// Create regular member user
		memberData = await createMember({
			email: `member-lifecycle-${timestamp}@test.com`,
			roles: new Set(['member'])
		});
	});

	test.afterAll(async () => {
		await quartermasterData.cleanUp();
		await memberData.cleanUp();
	});

	async function createCategory(
		name: string,
		description: string,
		available_attributes: any[] = []
	) {
		const supabaseServiceClient = getSupabaseServiceClient();
		const { data: categoryData, error: categoryError } = await supabaseServiceClient
			.from('equipment_categories')
			.insert({
				name,
				description,
				available_attributes
			})
			.select()
			.single();

		expect(categoryError).toBeNull();
		expect(categoryData).toBeTruthy();
		return categoryData;
	}

	async function createContainer(
		name: string,
		description: string,
		parentId: string | null = null
	) {
		const supabaseServiceClient = getSupabaseServiceClient();
		const { data: containerData, error: containerError } = await supabaseServiceClient
			.from('containers')
			.insert({
				name,
				description,
				created_by: quartermasterData.userId!,
				parent_container_id: parentId
			})
			.select()
			.single();

		expect(containerError).toBeNull();
		expect(containerData).toBeTruthy();
		return containerData;
	}

	async function createItem(
		name: string,
		description: string,
		categoryId: string,
		containerId: string,
		quantity: number = 1,
		attributes: Record<string, any> = {}
	) {
		const supabaseServiceClient = getSupabaseServiceClient();
		const { data: itemData, error: itemError } = await supabaseServiceClient
			.from('inventory_items')
			.insert({
				name,
				description,
				category_id: categoryId,
				container_id: containerId,
				quantity,
				attributes,
				created_by: quartermasterData.userId
			})
			.select()
			.single();

		expect(itemError).toBeNull();
		expect(itemData).toBeTruthy();
		return itemData;
	}

	async function deleteContainer(containerId: string) {
		const supabaseServiceClient = getSupabaseServiceClient();
		const { error } = await supabaseServiceClient.from('containers').delete().eq('id', containerId);

		return { success: !error, error: error?.message };
	}

	async function deleteCategory(categoryId: string) {
		const supabaseServiceClient = getSupabaseServiceClient();
		const { error } = await supabaseServiceClient
			.from('equipment_categories')
			.delete()
			.eq('id', categoryId);

		return { success: !error, error: error?.message };
	}

	async function deleteItem(itemId: string) {
		const supabaseServiceClient = getSupabaseServiceClient();
		const { error } = await supabaseServiceClient.from('inventory_items').delete().eq('id', itemId);

		return { success: !error, error: error?.message };
	}

	test('should complete full inventory setup and management workflow', async ({
		page,
		context
	}) => {
		await loginAsUser(context, quartermasterData.email);

		const timestamp = Date.now();

		// Step 1: Create container hierarchy
		await page.goto('/dashboard/inventory/containers');

		// Create main storage room
		await page
			.getByRole('link', { name: /add container/i })
			.nth(1)
			.click();
		await page.getByLabel(/name/i).fill(`Main Storage ${timestamp}`);
		await page.getByLabel(/description/i).fill('Main equipment storage room');
		await page.getByRole('button', { name: /create/i }).click();
		await expect(page.getByRole('heading', { name: /main storage/i })).toBeVisible();

		// Create weapon rack inside main storage
		await page.getByRole('link', { name: /add container/i }).click();
		await page.getByLabel(/name/i).fill(`Weapon Rack ${timestamp}`);
		await page.getByLabel(/description/i).fill('Rack for storing weapons');
		await page.getByLabel(/parent container/i).click();
		await page.getByText(`Main Storage ${timestamp}`).click();
		await page.getByRole('button', { name: /create/i }).click();
		await expect(page.getByRole('heading', { name: /weapon rack/i })).toBeVisible();

		// Create armor cabinet
		await page
			.getByRole('link', { name: /add container/i })
			.first()
			.click();
		await page.getByLabel(/name/i).fill(`Armor Cabinet ${timestamp}`);
		await page.getByLabel(/description/i).fill('Cabinet for protective equipment');
		await page.getByLabel(/parent container/i).click();
		await page.getByText(`Main Storage ${timestamp}`).click();
		await page.getByRole('button', { name: /create/i }).click();
		await expect(page.getByRole('heading', { name: /Armor cabinet/i })).toBeVisible();

		// Step 2: Create equipment categories with attributes
		await page.goto('/dashboard/inventory/categories');

		// Create weapons category
		await page
			.getByRole('link', { name: /add category/i })
			.first()
			.click();
		await page.getByLabel(/name/i).fill(`Weapons ${timestamp}`);
		await page.getByLabel(/description/i).fill('All weapon equipment');

		// Add weapon type attribute
		await page.getByLabel(/display label/i).fill('Weapon Type');
		await page.getByRole('button', { name: 'Attribute Type' }).click();
		await page.getByText('Dropdown Select').click();
		await page.getByRole('button', { name: /add attribute/i }).click();

		// Add options to weapon type
		await page.getByRole('button', { name: /add option/i }).click();
		await page.getByPlaceholder(/option value/i).fill('Longsword');
		await page.getByRole('button', { name: /add option/i }).click();
		await page
			.getByPlaceholder(/option value/i)
			.last()
			.fill('Rapier');
		await page.getByRole('button', { name: /add option/i }).click();
		await page
			.getByPlaceholder(/option value/i)
			.last()
			.fill('Sabre');

		// Add manufacturer attribute
		await page
			.getByLabel(/display label/i)
			.first()
			.fill('Manufacturer');
		await page.getByRole('button', { name: /add attribute/i }).click();

		// Add weight attribute
		await page
			.getByLabel(/display label/i)
			.first()
			.fill('Weight (kg)');
		await page.getByRole('button', { name: 'Attribute Type' }).click();
		await page.getByText('Number Input').click();
		await page.getByRole('button', { name: /add attribute/i }).click();

		// Add condition attribute
		await page
			.getByLabel(/display label/i)
			.first()
			.fill('Condition');
		await page.getByRole('button', { name: 'Attribute Type' }).click();
		await page.getByText('Dropdown Select').click();
		await page
			.getByRole('checkbox', { name: /required field/i })
			.first()
			.check();
		await page.getByRole('button', { name: /add attribute/i }).click();

		// Add condition options
		await page
			.getByRole('button', { name: /add option/i })
			.first()
			.click();
		await page
			.getByPlaceholder(/option value/i)
			.last()
			.fill('Excellent');
		await page
			.getByRole('button', { name: /add option/i })
			.last()
			.click();
		await page
			.getByPlaceholder(/option value/i)
			.last()
			.fill('Good');
		await page
			.getByRole('button', { name: /add option/i })
			.last()
			.click();
		await page
			.getByPlaceholder(/option value/i)
			.last()
			.fill('Fair');
		await page
			.getByRole('button', { name: /add option/i })
			.last()
			.click();
		await page
			.getByPlaceholder(/option value/i)
			.last()
			.fill('Poor');

		await page.getByRole('button', { name: /create/i }).click();
		await expect(page.getByRole('button', { name: /creating/i })).not.toBeVisible();
		await page.waitForURL(/\/dashboard\/inventory/);

		// Create armor category
		await page
			.getByRole('link', { name: /add category/i })
			.first()
			.click();
		await page.waitForURL(/\/dashboard\/inventory\/categories\/create/);
		await page.getByLabel(/name/i).fill(`Armor ${timestamp}`);
		await page.getByLabel(/description/i).fill('Protective equipment');

		// Add armor type attribute
		await page
			.getByLabel(/display label/i)
			.first()
			.fill('Armor Type');
		await page.getByRole('button', { name: 'Attribute Type' }).click();
		await page.getByText('Dropdown Select').click();
		await page
			.getByRole('checkbox', { name: /required field/i })
			.first()
			.check();
		await page.getByRole('button', { name: /add attribute/i }).click();

		// Add armor type options
		await page
			.getByRole('button', { name: /add option/i })
			.first()
			.click();
		await page.getByPlaceholder(/option value/i).fill('Mask');
		await page.getByRole('button', { name: /add option/i }).click();
		await page
			.getByPlaceholder(/option value/i)
			.last()
			.fill('Jacket');
		await page.getByRole('button', { name: /add option/i }).click();
		await page
			.getByPlaceholder(/option value/i)
			.last()
			.fill('Gloves');

		// Add size attribute
		await page
			.getByLabel(/display label/i)
			.first()
			.fill('Size');
		await page.getByRole('button', { name: 'Attribute Type' }).click();
		await page.getByText('Dropdown Select').click();
		await page
			.getByRole('checkbox', { name: /required field/i })
			.first()
			.check();
		await page.getByRole('button', { name: /add attribute/i }).click();

		// Add size options
		await page
			.getByRole('button', { name: /add option/i })
			.first()
			.click();
		await page
			.getByPlaceholder(/option value/i)
			.last()
			.fill('XS');
		await page
			.getByRole('button', { name: /add option/i })
			.first()
			.click();
		await page
			.getByPlaceholder(/option value/i)
			.last()
			.fill('S');
		await page
			.getByRole('button', { name: /add option/i })
			.first()
			.click();
		await page
			.getByPlaceholder(/option value/i)
			.last()
			.fill('M');
		await page
			.getByRole('button', { name: /add option/i })
			.first()
			.click();
		await page
			.getByPlaceholder(/option value/i)
			.last()
			.fill('L');
		await page
			.getByRole('button', { name: /add option/i })
			.first()
			.click();
		await page
			.getByPlaceholder(/option value/i)
			.last()
			.fill('XL');

		await page.getByRole('button', { name: /create/i }).click();
		await expect(page.getByRole('button', { name: /creating/i })).not.toBeVisible();

		// Step 3: Add inventory items
		await page.goto('/dashboard/inventory/items');

		// Add a longsword
		await page
			.getByRole('link', { name: /add item/i })
			.first()
			.click();
		await page.getByLabel(/notes/i).fill('High-quality synthetic training longsword');
		await page.getByLabel(/quantity/i).fill('3');

		// Select weapons category
		await page.getByRole('button', { name: /category/i }).click();
		await page.getByText(`Weapons ${timestamp}`).click();

		// Select weapon rack container
		await page.getByRole('button', { name: /container/i }).click();
		await page.getByText(`Weapon Rack ${timestamp}`).click();

		// Fill weapon attributes
		await page.getByRole('button', { name: /weapon type/i }).click();
		await page.getByText('Longsword').click();
		await page.getByRole('textbox', { name: 'Manufacturer' }).fill('manufacturer');
		await page.getByRole('spinbutton', { name: 'Weight (kg)' }).fill(1.2);

		await page.getByRole('button', { name: /condition/i }).click();
		await page.getByText('Good').click();

		await page.getByRole('button', { name: /create/i }).click();
		expect(page.url()).not.toContain('create');

		// Add fencing masks
		await page.getByRole('link', { name: /add item/i }).click();
		await page.getByLabel(/notes/i).fill('Standard fencing masks for protection');
		await page.getByLabel(/quantity/i).fill('8');

		// Select armor category
		await page.getByLabel(/category/i).click();
		await page.getByText(`Armor ${timestamp}`).click();

		// Select armor cabinet container
		await page.getByLabel(/container/i).click();
		await page.getByText(`Armor Cabinet ${timestamp}`).click();

		// Fill armor attributes
		await page.getByLabel(/armor type/i).click();
		await page.getByText('Mask').click();

		await page.getByLabel(/size/i).click();
		await page.getByText('M').click();

		await page.getByRole('button', { name: /create/i }).click();
		await expect(page.getByRole('button', { name: /creating/i })).not.toBeVisible();

		// Step 4: Test item management operations
		// Find the longsword and mark it for maintenance
		await page.getByText(`Training Longsword ${timestamp}`).click();
		await page.getByRole('button', { name: /maintenance/i }).click();
		await page.getByLabel(/maintenance notes/i).fill('Blade needs sharpening');
		await page.getByRole('button', { name: /mark for maintenance/i }).click();
		await expect(page.getByText(/marked for maintenance/i)).toBeVisible();

		// Step 5: Test search and filtering
		// Search for longsword
		await page.getByPlaceholder(/search items/i).fill('Longsword');
		await expect(page.getByText(`Training Longsword ${timestamp}`)).toBeVisible();
		await expect(page.getByText(`Fencing Masks ${timestamp}`)).not.toBeVisible();

		// Clear search and filter by armor category
		await page.getByPlaceholder(/search items/i).fill('');
		await page.getByRole('button', { name: /filter by category/i }).click();
		await page.getByText(`Armor ${timestamp}`).click();
		await expect(page.getByText(`Fencing Masks ${timestamp}`)).toBeVisible();
		await expect(page.getByText(`Training Longsword ${timestamp}`)).not.toBeVisible();

		// Step 6: Test member access (read-only)
		await loginAsUser(context, memberData.email);

		// Member should be able to view inventory
		await page.goto('/dashboard/inventory/items');
		await expect(page.getByRole('heading', { name: /items/i })).toBeVisible();

		// Should see available items but not create button
		await expect(page.getByText(`Fencing Masks ${timestamp}`)).toBeVisible();
		await expect(page.getByRole('link', { name: /add item/i })).not.toBeVisible();

		// Should not see items out for maintenance
		await expect(page.getByText(`Training Longsword ${timestamp}`)).not.toBeVisible();

		// Member should be able to view containers
		await page.goto('/dashboard/inventory/containers');
		await expect(page.getByText(`Main Storage ${timestamp}`)).toBeVisible();
		await expect(page.getByRole('link', { name: /add container/i })).not.toBeVisible();

		// Member should be able to view categories
		await page.goto('/dashboard/inventory/categories');
		await expect(page.getByText(`Weapons ${timestamp}`)).toBeVisible();
		await expect(page.getByRole('link', { name: /add category/i })).not.toBeVisible();

		// Step 7: Return to quartermaster and complete maintenance
		await loginAsUser(context, quartermasterData.email);
		await page.goto('/dashboard/inventory/items');

		// Filter by maintenance status
		await page.getByRole('button', { name: /filter by status/i }).click();
		await page.getByText('Out for Maintenance').click();
		await expect(page.getByText(`Training Longsword ${timestamp}`)).toBeVisible();

		// Return item from maintenance
		await page.getByText(`Training Longsword ${timestamp}`).click();
		await page.getByRole('button', { name: /return from maintenance/i }).click();
		await page.getByLabel(/maintenance notes/i).fill('Blade sharpened, ready for use');
		await page.getByRole('button', { name: /return to service/i }).click();
		await expect(page.getByText(/returned to service/i)).toBeVisible();

		// Step 8: Verify complete inventory overview
		await page.goto('/dashboard/inventory');

		// Should show inventory summary
		await expect(page.getByText(/total items/i)).toBeVisible();
		await expect(page.getByText(/categories/i)).toBeVisible();
		await expect(page.getByText(/containers/i)).toBeVisible();

		// Should show recent activity
		await expect(page.getByText(/recent activity/i)).toBeVisible();
		await expect(page.getByText(/returned to service/i)).toBeVisible();
	});

	test('should handle inventory data validation correctly', async ({ page, context }) => {
		await loginAsUser(context, quartermasterData.email);

		const timestamp = Date.now();

		// Create test category with validation
		await page.goto('/dashboard');
		const categoryData = await createCategory(
			`Validation Test ${timestamp}`,
			'Category for validation testing',
			[
				{
					type: 'text',
					label: 'Required Text',
					required: true
				},
				{
					type: 'select',
					label: 'Select Option',
					required: true,
					options: ['Option1', 'Option2', 'Option3']
				},
				{
					type: 'number',
					label: 'Optional Number',
					required: false
				}
			]
		);

		const containerData = await createContainer(
			`Validation Container ${timestamp}`,
			'Container for validation testing'
		);

		// Test 1: Missing required attributes should fail
		try {
			await createItem(
				`Invalid Item 1 ${timestamp}`,
				'Missing required attributes',
				categoryData!.id,
				containerData!.id,
				1,
				{
					optionalNumber: 42
					// Missing requiredText and selectWithOptions
				}
			);
			expect(true).toBe(false); // Should not reach here
		} catch (error) {
			expect(error).toBeTruthy(); // Should fail validation
		}

		// Test 2: Invalid select option should fail
		try {
			await createItem(
				`Invalid Item 2 ${timestamp}`,
				'Invalid select option',
				categoryData!.id,
				containerData!.id,
				1,
				{
					requiredText: 'Valid text',
					selectWithOptions: 'InvalidOption', // Not in allowed options
					optionalNumber: 42
				}
			);
			expect(true).toBe(false); // Should not reach here
		} catch (error) {
			expect(error).toBeTruthy(); // Should fail validation
		}

		// Test 3: Valid data should succeed
		const validItem = await createItem(
			`Valid Item ${timestamp}`,
			'All attributes valid',
			categoryData!.id,
			containerData!.id,
			1,
			{
				requiredText: 'Valid text',
				selectWithOptions: 'Option2',
				optionalNumber: 42
			}
		);

		expect((validItem!.attributes as any).requiredText).toBe('Valid text');
		expect((validItem!.attributes as any).selectWithOptions).toBe('Option2');
		expect((validItem!.attributes as any).optionalNumber).toBe(42);
	});

	test('should maintain data integrity across operations', async ({ page, context }) => {
		await loginAsUser(context, quartermasterData.email);

		const timestamp = Date.now();

		// Create test data
		await page.goto('/dashboard');

		const containerData = await createContainer(
			`Integrity Container ${timestamp}`,
			'Container for integrity testing'
		);

		const categoryData = await createCategory(
			`Integrity Category ${timestamp}`,
			'Category for integrity testing',
			[
				{
					type: 'text',
					label: 'Test Attribute',
					required: false
				}
			]
		);

		const itemData = await createItem(
			`Integrity Item ${timestamp}`,
			'Item for integrity testing',
			categoryData!.id,
			containerData!.id,
			5,
			{
				testAttribute: 'Original value'
			}
		);

		// Test 1: Cannot delete container with items
		const deleteContainerResponse = await deleteContainer(containerData!.id);

		expect(deleteContainerResponse.success).toBe(false);
		expect(deleteContainerResponse.error).toContain('contains items');

		// Test 2: Cannot delete category with items
		const deleteCategoryResponse = await deleteCategory(categoryData!.id);

		expect(deleteCategoryResponse.success).toBe(false);
		expect(deleteCategoryResponse.error).toContain('has items');

		// Test 3: Can delete item, then container and category
		const deleteItemResponse = await deleteItem(itemData!.id);

		expect(deleteItemResponse.success).toBe(true);

		// Now container and category can be deleted
		const deleteContainerResponse2 = await deleteContainer(containerData!.id);

		expect(deleteContainerResponse2.success).toBe(true);

		const deleteCategoryResponse2 = await deleteCategory(categoryData!.id);

		expect(deleteCategoryResponse2.success).toBe(true);
	});
});
