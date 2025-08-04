import { expect, test } from '@playwright/test';
import { createMember } from './setupFunctions';
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

	test('should complete full inventory setup and management workflow', async ({ page, context }) => {
		await loginAsUser(context, quartermasterData.email);
		
		const timestamp = Date.now();

		// Step 1: Create container hierarchy
		await page.goto('/dashboard/inventory/containers');
		
		// Create main storage room
		await page.getByRole('button', { name: /create container/i }).click();
		await page.getByLabel(/name/i).fill(`Main Storage ${timestamp}`);
		await page.getByLabel(/description/i).fill('Main equipment storage room');
		await page.getByLabel(/location/i).fill('Building A, Room 101');
		await page.getByRole('button', { name: /create/i }).click();
		await expect(page.getByText(/container created successfully/i)).toBeVisible();

		// Create weapon rack inside main storage
		await page.getByRole('button', { name: /create container/i }).click();
		await page.getByLabel(/name/i).fill(`Weapon Rack ${timestamp}`);
		await page.getByLabel(/description/i).fill('Rack for storing weapons');
		await page.getByLabel(/parent container/i).click();
		await page.getByText(`Main Storage ${timestamp}`).click();
		await page.getByRole('button', { name: /create/i }).click();
		await expect(page.getByText(/container created successfully/i)).toBeVisible();

		// Create armor cabinet
		await page.getByRole('button', { name: /create container/i }).click();
		await page.getByLabel(/name/i).fill(`Armor Cabinet ${timestamp}`);
		await page.getByLabel(/description/i).fill('Cabinet for protective equipment');
		await page.getByLabel(/parent container/i).click();
		await page.getByText(`Main Storage ${timestamp}`).click();
		await page.getByRole('button', { name: /create/i }).click();
		await expect(page.getByText(/container created successfully/i)).toBeVisible();

		// Step 2: Create equipment categories with attributes
		await page.goto('/dashboard/inventory/categories');

		// Create weapons category
		await page.getByRole('button', { name: /create category/i }).click();
		await page.getByLabel(/name/i).fill(`Weapons ${timestamp}`);
		await page.getByLabel(/description/i).fill('All weapon equipment');

		// Add weapon type attribute
		await page.getByLabel(/display label/i).fill('Weapon Type');
		await page.getByRole('combobox', { name: /attribute type/i }).click();
		await page.getByText('Dropdown Select').click();
		await page.getByRole('button', { name: /add attribute/i }).click();

		// Add options to weapon type
		await page.getByRole('button', { name: /add option/i }).click();
		await page.getByPlaceholder(/option value/i).fill('Longsword');
		await page.getByRole('button', { name: /add option/i }).click();
		await page.getByPlaceholder(/option value/i).last().fill('Rapier');
		await page.getByRole('button', { name: /add option/i }).click();
		await page.getByPlaceholder(/option value/i).last().fill('Sabre');

		// Add manufacturer attribute
		await page.getByLabel(/display label/i).fill('Manufacturer');
		await page.getByRole('button', { name: /add attribute/i }).click();

		// Add weight attribute
		await page.getByLabel(/display label/i).fill('Weight (kg)');
		await page.getByRole('combobox', { name: /attribute type/i }).click();
		await page.getByText('Number Input').click();
		await page.getByRole('button', { name: /add attribute/i }).click();

		// Add condition attribute
		await page.getByLabel(/display label/i).fill('Condition');
		await page.getByRole('combobox', { name: /attribute type/i }).click();
		await page.getByText('Dropdown Select').click();
		await page.getByRole('checkbox', { name: /required field/i }).check();
		await page.getByRole('button', { name: /add attribute/i }).click();

		// Add condition options
		await page.getByRole('button', { name: /add option/i }).click();
		await page.getByPlaceholder(/option value/i).last().fill('Excellent');
		await page.getByRole('button', { name: /add option/i }).click();
		await page.getByPlaceholder(/option value/i).last().fill('Good');
		await page.getByRole('button', { name: /add option/i }).click();
		await page.getByPlaceholder(/option value/i).last().fill('Fair');
		await page.getByRole('button', { name: /add option/i }).click();
		await page.getByPlaceholder(/option value/i).last().fill('Poor');

		await page.getByRole('button', { name: /create/i }).click();
		await expect(page.getByText(/category created successfully/i)).toBeVisible();

		// Create armor category
		await page.getByRole('button', { name: /create category/i }).click();
		await page.getByLabel(/name/i).fill(`Armor ${timestamp}`);
		await page.getByLabel(/description/i).fill('Protective equipment');

		// Add armor type attribute
		await page.getByLabel(/display label/i).fill('Armor Type');
		await page.getByRole('combobox', { name: /attribute type/i }).click();
		await page.getByText('Dropdown Select').click();
		await page.getByRole('checkbox', { name: /required field/i }).check();
		await page.getByRole('button', { name: /add attribute/i }).click();

		// Add armor type options
		await page.getByRole('button', { name: /add option/i }).click();
		await page.getByPlaceholder(/option value/i).fill('Mask');
		await page.getByRole('button', { name: /add option/i }).click();
		await page.getByPlaceholder(/option value/i).last().fill('Jacket');
		await page.getByRole('button', { name: /add option/i }).click();
		await page.getByPlaceholder(/option value/i).last().fill('Gloves');

		// Add size attribute
		await page.getByLabel(/display label/i).fill('Size');
		await page.getByRole('combobox', { name: /attribute type/i }).click();
		await page.getByText('Dropdown Select').click();
		await page.getByRole('checkbox', { name: /required field/i }).check();
		await page.getByRole('button', { name: /add attribute/i }).click();

		// Add size options
		await page.getByRole('button', { name: /add option/i }).click();
		await page.getByPlaceholder(/option value/i).last().fill('XS');
		await page.getByRole('button', { name: /add option/i }).click();
		await page.getByPlaceholder(/option value/i).last().fill('S');
		await page.getByRole('button', { name: /add option/i }).click();
		await page.getByPlaceholder(/option value/i).last().fill('M');
		await page.getByRole('button', { name: /add option/i }).click();
		await page.getByPlaceholder(/option value/i).last().fill('L');
		await page.getByRole('button', { name: /add option/i }).click();
		await page.getByPlaceholder(/option value/i).last().fill('XL');

		await page.getByRole('button', { name: /create/i }).click();
		await expect(page.getByText(/category created successfully/i)).toBeVisible();

		// Step 3: Add inventory items
		await page.goto('/dashboard/inventory/items');

		// Add a longsword
		await page.getByRole('button', { name: /create item/i }).click();
		await page.getByLabel(/name/i).fill(`Training Longsword ${timestamp}`);
		await page.getByLabel(/description/i).fill('High-quality synthetic training longsword');
		await page.getByLabel(/quantity/i).fill('3');

		// Select weapons category
		await page.getByLabel(/category/i).click();
		await page.getByText(`Weapons ${timestamp}`).click();

		// Select weapon rack container
		await page.getByLabel(/container/i).click();
		await page.getByText(`Weapon Rack ${timestamp}`).click();

		// Fill weapon attributes
		await page.getByLabel(/weapon type/i).click();
		await page.getByText('Longsword').click();

		await page.getByLabel(/manufacturer/i).fill('Red Dragon Armoury');
		await page.getByLabel(/weight/i).fill('1.2');

		await page.getByLabel(/condition/i).click();
		await page.getByText('Good').click();

		await page.getByRole('button', { name: /create/i }).click();
		await expect(page.getByText(/item created successfully/i)).toBeVisible();

		// Add fencing masks
		await page.getByRole('button', { name: /create item/i }).click();
		await page.getByLabel(/name/i).fill(`Fencing Masks ${timestamp}`);
		await page.getByLabel(/description/i).fill('Standard fencing masks for protection');
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
		await expect(page.getByText(/item created successfully/i)).toBeVisible();

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
		await page.getByRole('combobox', { name: /filter by category/i }).click();
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
		await expect(page.getByRole('button', { name: /create item/i })).not.toBeVisible();

		// Should not see items out for maintenance
		await expect(page.getByText(`Training Longsword ${timestamp}`)).not.toBeVisible();

		// Member should be able to view containers
		await page.goto('/dashboard/inventory/containers');
		await expect(page.getByText(`Main Storage ${timestamp}`)).toBeVisible();
		await expect(page.getByRole('button', { name: /create container/i })).not.toBeVisible();

		// Member should be able to view categories
		await page.goto('/dashboard/inventory/categories');
		await expect(page.getByText(`Weapons ${timestamp}`)).toBeVisible();
		await expect(page.getByRole('button', { name: /create category/i })).not.toBeVisible();

		// Step 7: Return to quartermaster and complete maintenance
		await loginAsUser(context, quartermasterData.email);
		await page.goto('/dashboard/inventory/items');

		// Filter by maintenance status
		await page.getByRole('combobox', { name: /filter by status/i }).click();
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
		const categoryResponse = await makeAuthenticatedRequest(page, '/api/inventory/categories', {
			method: 'POST',
			data: {
				name: `Validation Test ${timestamp}`,
				description: 'Category for validation testing',
				available_attributes: {
					requiredText: {
						type: 'text',
						label: 'Required Text',
						required: true
					},
					selectWithOptions: {
						type: 'select',
						label: 'Select Option',
						required: true,
						options: ['Option1', 'Option2', 'Option3']
					},
					optionalNumber: {
						type: 'number',
						label: 'Optional Number',
						required: false
					}
				}
			}
		});

		const containerResponse = await makeAuthenticatedRequest(page, '/api/inventory/containers', {
			method: 'POST',
			data: {
				name: `Validation Container ${timestamp}`,
				description: 'Container for validation testing'
			}
		});

		// Test 1: Missing required attributes should fail
		const invalidResponse1 = await makeAuthenticatedRequest(page, '/api/inventory/items', {
			method: 'POST',
			data: {
				name: `Invalid Item 1 ${timestamp}`,
				description: 'Missing required attributes',
				category_id: categoryResponse.category.id,
				container_id: containerResponse.container.id,
				quantity: 1,
				attributes: {
					optionalNumber: 42
					// Missing requiredText and selectWithOptions
				}
			}
		});

		expect(invalidResponse1.success).toBe(false);
		expect(invalidResponse1.error).toContain('validation');

		// Test 2: Invalid select option should fail
		const invalidResponse2 = await makeAuthenticatedRequest(page, '/api/inventory/items', {
			method: 'POST',
			data: {
				name: `Invalid Item 2 ${timestamp}`,
				description: 'Invalid select option',
				category_id: categoryResponse.category.id,
				container_id: containerResponse.container.id,
				quantity: 1,
				attributes: {
					requiredText: 'Valid text',
					selectWithOptions: 'InvalidOption', // Not in allowed options
					optionalNumber: 42
				}
			}
		});

		expect(invalidResponse2.success).toBe(false);
		expect(invalidResponse2.error).toContain('validation');

		// Test 3: Valid data should succeed
		const validResponse = await makeAuthenticatedRequest(page, '/api/inventory/items', {
			method: 'POST',
			data: {
				name: `Valid Item ${timestamp}`,
				description: 'All attributes valid',
				category_id: categoryResponse.category.id,
				container_id: containerResponse.container.id,
				quantity: 1,
				attributes: {
					requiredText: 'Valid text',
					selectWithOptions: 'Option2',
					optionalNumber: 42
				}
			}
		});

		expect(validResponse.success).toBe(true);
		expect(validResponse.item.attributes.requiredText).toBe('Valid text');
		expect(validResponse.item.attributes.selectWithOptions).toBe('Option2');
		expect(validResponse.item.attributes.optionalNumber).toBe(42);
	});

	test('should maintain data integrity across operations', async ({ page, context }) => {
		await loginAsUser(context, quartermasterData.email);
		
		const timestamp = Date.now();

		// Create test data
		await page.goto('/dashboard');
		
		const containerResponse = await makeAuthenticatedRequest(page, '/api/inventory/containers', {
			method: 'POST',
			data: {
				name: `Integrity Container ${timestamp}`,
				description: 'Container for integrity testing'
			}
		});

		const categoryResponse = await makeAuthenticatedRequest(page, '/api/inventory/categories', {
			method: 'POST',
			data: {
				name: `Integrity Category ${timestamp}`,
				description: 'Category for integrity testing',
				available_attributes: {
					testAttribute: {
						type: 'text',
						label: 'Test Attribute',
						required: false
					}
				}
			}
		});

		const itemResponse = await makeAuthenticatedRequest(page, '/api/inventory/items', {
			method: 'POST',
			data: {
				name: `Integrity Item ${timestamp}`,
				description: 'Item for integrity testing',
				category_id: categoryResponse.category.id,
				container_id: containerResponse.container.id,
				quantity: 5,
				attributes: {
					testAttribute: 'Original value'
				}
			}
		});

		// Test 1: Cannot delete container with items
		const deleteContainerResponse = await makeAuthenticatedRequest(page, `/api/inventory/containers/${containerResponse.container.id}`, {
			method: 'DELETE'
		});

		expect(deleteContainerResponse.success).toBe(false);
		expect(deleteContainerResponse.error).toContain('contains items');

		// Test 2: Cannot delete category with items
		const deleteCategoryResponse = await makeAuthenticatedRequest(page, `/api/inventory/categories/${categoryResponse.category.id}`, {
			method: 'DELETE'
		});

		expect(deleteCategoryResponse.success).toBe(false);
		expect(deleteCategoryResponse.error).toContain('has items');

		// Test 3: Can delete item, then container and category
		const deleteItemResponse = await makeAuthenticatedRequest(page, `/api/inventory/items/${itemResponse.item.id}`, {
			method: 'DELETE'
		});

		expect(deleteItemResponse.success).toBe(true);

		// Now container and category can be deleted
		const deleteContainerResponse2 = await makeAuthenticatedRequest(page, `/api/inventory/containers/${containerResponse.container.id}`, {
			method: 'DELETE'
		});

		expect(deleteContainerResponse2.success).toBe(true);

		const deleteCategoryResponse2 = await makeAuthenticatedRequest(page, `/api/inventory/categories/${categoryResponse.category.id}`, {
			method: 'DELETE'
		});

		expect(deleteCategoryResponse2.success).toBe(true);
	});
});