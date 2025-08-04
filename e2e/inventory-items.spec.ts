import { expect, test } from '@playwright/test';
import { createMember } from './setupFunctions';
import { loginAsUser } from './supabaseLogin';

test.describe('Inventory Items Management', () => {
	let quartermasterData: Awaited<ReturnType<typeof createMember>>;
	let memberData: Awaited<ReturnType<typeof createMember>>;
	let adminData: Awaited<ReturnType<typeof createMember>>;

	// Test data IDs to be set up in beforeAll
	let testCategoryId: string;
	let testContainerId: string;
	let weaponsCategoryId: string;
	let armorCategoryId: string;

	test.beforeAll(async () => {
		const timestamp = Date.now();

		// Create users
		quartermasterData = await createMember({
			email: `quartermaster-items-${timestamp}@test.com`,
			roles: new Set(['quartermaster'])
		});

		memberData = await createMember({
			email: `member-items-${timestamp}@test.com`,
			roles: new Set(['member'])
		});

		adminData = await createMember({
			email: `admin-items-${timestamp}@test.com`,
			roles: new Set(['admin'])
		});

		// Set up test data via API using quartermaster account
		const page = quartermasterData.session?.user ? 
			{ request: { fetch: async (url: string, options: any) => {
				const response = await fetch(url, {
					...options,
					headers: {
						'Authorization': `Bearer ${quartermasterData.session?.access_token}`,
						'Content-Type': 'application/json',
						...options.headers
					}
				});
				return response;
			}}} : null;

		if (page) {
			// Create test container
			const containerResponse = await page.request.fetch('/api/inventory/containers', {
				method: 'POST',
				data: JSON.stringify({
					name: `Test Container ${timestamp}`,
					description: 'Container for test items',
					location: 'Test location'
				})
			});
			const containerData = await containerResponse.json();
			testContainerId = containerData.container.id;

			// Create basic test category
			const categoryResponse = await page.request.fetch('/api/inventory/categories', {
				method: 'POST',
				data: JSON.stringify({
					name: `Test Category ${timestamp}`,
					description: 'Basic category for testing',
					available_attributes: {
						brand: {
							type: 'text',
							label: 'Brand',
							required: false
						},
						condition: {
							type: 'select',
							label: 'Condition',
							required: true,
							options: ['New', 'Good', 'Fair', 'Poor']
						}
					}
				})
			});
			const categoryData = await categoryResponse.json();
			testCategoryId = categoryData.category.id;

			// Create weapons category with complex attributes
			const weaponsResponse = await page.request.fetch('/api/inventory/categories', {
				method: 'POST',
				data: JSON.stringify({
					name: `Weapons ${timestamp}`,
					description: 'Weapons category with complex attributes',
					available_attributes: {
						weaponType: {
							type: 'select',
							label: 'Weapon Type',
							required: true,
							options: ['Longsword', 'Rapier', 'Sabre', 'Dagger']
						},
						manufacturer: {
							type: 'text',
							label: 'Manufacturer',
							required: false
						},
						weight: {
							type: 'number',
							label: 'Weight (kg)',
							required: false
						},
						inMaintenance: {
							type: 'boolean',
							label: 'In Maintenance',
							required: false
						}
					}
				})
			});
			const weaponsData = await weaponsResponse.json();
			weaponsCategoryId = weaponsData.category.id;

			// Create armor category
			const armorResponse = await page.request.fetch('/api/inventory/categories', {
				method: 'POST',
				data: JSON.stringify({
					name: `Armor ${timestamp}`,
					description: 'Armor and protective equipment',
					available_attributes: {
						armorType: {
							type: 'select',
							label: 'Armor Type',
							required: true,
							options: ['Mask', 'Jacket', 'Gloves', 'Pants']
						},
						size: {
							type: 'select',
							label: 'Size',
							required: true,
							options: ['XS', 'S', 'M', 'L', 'XL', 'XXL']
						}
					}
				})
			});
			const armorData = await armorResponse.json();
			armorCategoryId = armorData.category.id;
		}
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

	test.describe('Item CRUD Operations', () => {
		test('should create basic item as quartermaster', async ({ page, context }) => {
			await loginAsUser(context, quartermasterData.email);
			await page.goto('/dashboard/inventory/items');

			const timestamp = Date.now();
			const itemName = `Test Item ${timestamp}`;

			// Click create item button
			await page.getByRole('button', { name: /create item/i }).click();

			// Fill basic form
			await page.getByLabel(/name/i).fill(itemName);
			await page.getByLabel(/description/i).fill('Test item for inventory');
			await page.getByLabel(/quantity/i).fill('5');

			// Select category
			await page.getByLabel(/category/i).click();
			await page.getByText('Test Category').click();

			// Select container
			await page.getByLabel(/container/i).click();
			await page.getByText('Test Container').click();

			// Fill required attributes
			await page.getByLabel(/condition/i).click();
			await page.getByText('Good').click();

			// Submit form
			await page.getByRole('button', { name: /create/i }).click();

			// Should show success message
			await expect(page.getByText(/item created successfully/i)).toBeVisible();

			// Should appear in items list
			await expect(page.getByText(itemName)).toBeVisible();
		});

		test('should create item with complex attributes', async ({ page, context }) => {
			await loginAsUser(context, quartermasterData.email);
			await page.goto('/dashboard/inventory/items');

			const timestamp = Date.now();
			const itemName = `Longsword ${timestamp}`;

			// Click create item button
			await page.getByRole('button', { name: /create item/i }).click();

			// Fill basic form
			await page.getByLabel(/name/i).fill(itemName);
			await page.getByLabel(/description/i).fill('High-quality training longsword');
			await page.getByLabel(/quantity/i).fill('1');

			// Select weapons category
			await page.getByLabel(/category/i).click();
			await page.getByText('Weapons').click();

			// Select container
			await page.getByLabel(/container/i).click();
			await page.getByText('Test Container').click();

			// Fill weapon-specific attributes
			await page.getByLabel(/weapon type/i).click();
			await page.getByText('Longsword').click();

			await page.getByLabel(/manufacturer/i).fill('Albion Swords');
			await page.getByLabel(/weight/i).fill('1.5');

			// Check maintenance status
			await page.getByLabel(/in maintenance/i).check();

			// Submit form
			await page.getByRole('button', { name: /create/i }).click();

			// Should show success message
			await expect(page.getByText(/item created successfully/i)).toBeVisible();

			// Should appear in items list
			await expect(page.getByText(itemName)).toBeVisible();
		});

		test('should edit item and update attributes', async ({ page, context }) => {
			await loginAsUser(context, quartermasterData.email);
			
			const timestamp = Date.now();
			const originalName = `Original Item ${timestamp}`;
			const updatedName = `Updated Item ${timestamp}`;

			// Create item first via API
			await page.goto('/dashboard');
			const createResponse = await makeAuthenticatedRequest(page, '/api/inventory/items', {
				method: 'POST',
				data: {
					name: originalName,
					description: 'Original description',
					category_id: testCategoryId,
					container_id: testContainerId,
					quantity: 3,
					attributes: {
						brand: 'Original Brand',
						condition: 'Good'
					}
				}
			});

			const itemId = createResponse.item.id;

			// Navigate to edit page
			await page.goto(`/dashboard/inventory/items/${itemId}/edit`);

			// Update basic info
			await page.getByLabel(/name/i).fill(updatedName);
			await page.getByLabel(/description/i).fill('Updated description');
			await page.getByLabel(/quantity/i).fill('7');

			// Update attributes
			await page.getByLabel(/brand/i).fill('Updated Brand');
			await page.getByLabel(/condition/i).click();
			await page.getByText('Fair').click();

			// Submit changes
			await page.getByRole('button', { name: /update/i }).click();

			// Should show success message
			await expect(page.getByText(/item updated successfully/i)).toBeVisible();

			// Should redirect to items list
			await expect(page).toHaveURL('/dashboard/inventory/items');

			// Should show updated name
			await expect(page.getByText(updatedName)).toBeVisible();
		});

		test('should delete item', async ({ page, context }) => {
			await loginAsUser(context, quartermasterData.email);
			await page.goto('/dashboard/inventory/items');

			const timestamp = Date.now();
			const itemName = `Delete Me ${timestamp}`;

			// Create item first
			await page.getByRole('button', { name: /create item/i }).click();
			await page.getByLabel(/name/i).fill(itemName);
			await page.getByLabel(/description/i).fill('Item to be deleted');
			await page.getByLabel(/quantity/i).fill('1');
			await page.getByLabel(/category/i).click();
			await page.getByText('Test Category').click();
			await page.getByLabel(/container/i).click();
			await page.getByText('Test Container').click();
			await page.getByLabel(/condition/i).click();
			await page.getByText('Good').click();
			await page.getByRole('button', { name: /create/i }).click();
			await expect(page.getByText(/item created successfully/i)).toBeVisible();

			// Find and delete the item
			await page.getByText(itemName).click();
			await page.getByRole('button', { name: /delete/i }).click();

			// Confirm deletion
			await page.getByRole('button', { name: /confirm/i }).click();

			// Should show success message
			await expect(page.getByText(/item deleted successfully/i)).toBeVisible();

			// Should not appear in list
			await expect(page.getByText(itemName)).not.toBeVisible();
		});

		test('should update item quantity', async ({ page, context }) => {
			await loginAsUser(context, quartermasterData.email);
			
			const timestamp = Date.now();
			const itemName = `Quantity Test ${timestamp}`;

			// Create item via API
			await page.goto('/dashboard');
			await makeAuthenticatedRequest(page, '/api/inventory/items', {
				method: 'POST',
				data: {
					name: itemName,
					description: 'Item for quantity testing',
					category_id: testCategoryId,
					container_id: testContainerId,
					quantity: 10,
					attributes: {
						condition: 'Good'
					}
				}
			});

			// Navigate to items page
			await page.goto('/dashboard/inventory/items');

			// Find item and update quantity
			await page.getByText(itemName).click();
			await page.getByRole('button', { name: /edit quantity/i }).click();

			// Update quantity
			await page.getByLabel(/quantity/i).fill('15');
			await page.getByRole('button', { name: /update/i }).click();

			// Should show success message
			await expect(page.getByText(/quantity updated successfully/i)).toBeVisible();

			// Should show updated quantity
			await expect(page.getByText('15')).toBeVisible();
		});
	});

	test.describe('Item API Endpoints', () => {
		test('should create item via API as quartermaster', async ({ page, context }) => {
			await loginAsUser(context, quartermasterData.email);
			await page.goto('/dashboard');

			const timestamp = Date.now();
			const itemData = {
				name: `API Item ${timestamp}`,
				description: 'Item created via API',
				category_id: testCategoryId,
				container_id: testContainerId,
				quantity: 3,
				attributes: {
					brand: 'API Brand',
					condition: 'New'
				}
			};

			const response = await makeAuthenticatedRequest(page, '/api/inventory/items', {
				method: 'POST',
				data: itemData
			});

			expect(response.success).toBe(true);
			expect(response.item.name).toBe(itemData.name);
			expect(response.item.description).toBe(itemData.description);
			expect(response.item.quantity).toBe(itemData.quantity);
			expect(response.item.attributes).toEqual(itemData.attributes);
		});

		test('should update item via API', async ({ page, context }) => {
			await loginAsUser(context, quartermasterData.email);
			await page.goto('/dashboard');

			const timestamp = Date.now();

			// Create item
			const createResponse = await makeAuthenticatedRequest(page, '/api/inventory/items', {
				method: 'POST',
				data: {
					name: `Update Test ${timestamp}`,
					description: 'Original description',
					category_id: testCategoryId,
					container_id: testContainerId,
					quantity: 5,
					attributes: {
						brand: 'Original Brand',
						condition: 'Good'
					}
				}
			});

			const itemId = createResponse.item.id;

			// Update item
			const updateResponse = await makeAuthenticatedRequest(page, `/api/inventory/items/${itemId}`, {
				method: 'PUT',
				data: {
					name: `Updated Test ${timestamp}`,
					description: 'Updated description',
					quantity: 8,
					attributes: {
						brand: 'Updated Brand',
						condition: 'Fair'
					}
				}
			});

			expect(updateResponse.success).toBe(true);
			expect(updateResponse.item.name).toBe(`Updated Test ${timestamp}`);
			expect(updateResponse.item.description).toBe('Updated description');
			expect(updateResponse.item.quantity).toBe(8);
			expect(updateResponse.item.attributes.brand).toBe('Updated Brand');
		});

		test('should delete item via API', async ({ page, context }) => {
			await loginAsUser(context, quartermasterData.email);
			await page.goto('/dashboard');

			const timestamp = Date.now();

			// Create item
			const createResponse = await makeAuthenticatedRequest(page, '/api/inventory/items', {
				method: 'POST',
				data: {
					name: `Delete Test ${timestamp}`,
					description: 'Item to delete',
					category_id: testCategoryId,
					container_id: testContainerId,
					quantity: 1,
					attributes: {
						condition: 'Good'
					}
				}
			});

			const itemId = createResponse.item.id;

			// Delete item
			const deleteResponse = await makeAuthenticatedRequest(page, `/api/inventory/items/${itemId}`, {
				method: 'DELETE'
			});

			expect(deleteResponse.success).toBe(true);
		});

		test('should validate required attributes', async ({ page, context }) => {
			await loginAsUser(context, quartermasterData.email);
			await page.goto('/dashboard');

			const timestamp = Date.now();

			// Try to create item without required condition attribute
			const response = await makeAuthenticatedRequest(page, '/api/inventory/items', {
				method: 'POST',
				data: {
					name: `Invalid Item ${timestamp}`,
					description: 'Item missing required attributes',
					category_id: testCategoryId,
					container_id: testContainerId,
					quantity: 1,
					attributes: {
						brand: 'Some Brand'
						// Missing required 'condition' attribute
					}
				}
			});

			expect(response.success).toBe(false);
			expect(response.error).toContain('validation');
		});

		test('should reject invalid attribute values', async ({ page, context }) => {
			await loginAsUser(context, quartermasterData.email);
			await page.goto('/dashboard');

			const timestamp = Date.now();

			// Try to create item with invalid select option
			const response = await makeAuthenticatedRequest(page, '/api/inventory/items', {
				method: 'POST',
				data: {
					name: `Invalid Item ${timestamp}`,
					description: 'Item with invalid attribute value',
					category_id: testCategoryId,
					container_id: testContainerId,
					quantity: 1,
					attributes: {
						brand: 'Valid Brand',
						condition: 'Invalid Condition' // Not in allowed options
					}
				}
			});

			expect(response.success).toBe(false);
			expect(response.error).toContain('validation');
		});

		test('should reject invalid data', async ({ page, context }) => {
			await loginAsUser(context, quartermasterData.email);
			await page.goto('/dashboard');

			const invalidData = {
				name: '', // Invalid: empty name
				description: 'Valid description',
				category_id: testCategoryId,
				container_id: testContainerId,
				quantity: -1, // Invalid: negative quantity
				attributes: {}
			};

			const response = await makeAuthenticatedRequest(page, '/api/inventory/items', {
				method: 'POST',
				data: invalidData
			});

			expect(response.success).toBe(false);
			expect(response.error).toBe('Invalid data');
			expect(response.issues).toBeDefined();
		});
	});

	test.describe('Item Status Management', () => {
		test('should mark item as out for maintenance', async ({ page, context }) => {
			await loginAsUser(context, quartermasterData.email);
			
			const timestamp = Date.now();
			const itemName = `Maintenance Item ${timestamp}`;

			// Create item via API
			await page.goto('/dashboard');
			const createResponse = await makeAuthenticatedRequest(page, '/api/inventory/items', {
				method: 'POST',
				data: {
					name: itemName,
					description: 'Item for maintenance testing',
					category_id: testCategoryId,
					container_id: testContainerId,
					quantity: 1,
					attributes: {
						condition: 'Good'
					}
				}
			});

			const itemId = createResponse.item.id;

			// Mark as out for maintenance
			const maintenanceResponse = await makeAuthenticatedRequest(page, `/api/inventory/items/${itemId}/maintenance`, {
				method: 'POST',
				data: {
					status: 'out_for_maintenance',
					notes: 'Needs blade sharpening'
				}
			});

			expect(maintenanceResponse.success).toBe(true);
			expect(maintenanceResponse.item.status).toBe('out_for_maintenance');
		});

		test('should return item from maintenance', async ({ page, context }) => {
			await loginAsUser(context, quartermasterData.email);
			
			const timestamp = Date.now();
			const itemName = `Return Item ${timestamp}`;

			// Create item and mark as out for maintenance via API
			await page.goto('/dashboard');
			const createResponse = await makeAuthenticatedRequest(page, '/api/inventory/items', {
				method: 'POST',
				data: {
					name: itemName,
					description: 'Item for return testing',
					category_id: testCategoryId,
					container_id: testContainerId,
					quantity: 1,
					attributes: {
						condition: 'Good'
					}
				}
			});

			const itemId = createResponse.item.id;

			// Mark as out for maintenance first
			await makeAuthenticatedRequest(page, `/api/inventory/items/${itemId}/maintenance`, {
				method: 'POST',
				data: {
					status: 'out_for_maintenance',
					notes: 'Needs repair'
				}
			});

			// Return from maintenance
			const returnResponse = await makeAuthenticatedRequest(page, `/api/inventory/items/${itemId}/maintenance`, {
				method: 'POST',
				data: {
					status: 'available',
					notes: 'Repair completed'
				}
			});

			expect(returnResponse.success).toBe(true);
			expect(returnResponse.item.status).toBe('available');
		});
	});

	test.describe('Access Control', () => {
		test('should allow quartermaster full access to items', async ({ page, context }) => {
			await loginAsUser(context, quartermasterData.email);
			await page.goto('/dashboard/inventory/items');

			// Should see create button
			await expect(page.getByRole('button', { name: /create item/i })).toBeVisible();

			// Should be able to access items page
			await expect(page.getByRole('heading', { name: /items/i })).toBeVisible();
		});

		test('should allow members read-only access to available items', async ({ page, context }) => {
			await loginAsUser(context, memberData.email);
			await page.goto('/dashboard/inventory/items');

			// Should be able to view items
			await expect(page.getByRole('heading', { name: /items/i })).toBeVisible();

			// Should not see create button
			await expect(page.getByRole('button', { name: /create item/i })).not.toBeVisible();

			// Should not see items out for maintenance
			// (This would require creating a maintenance item first and checking it's not visible)
		});

		test('should deny member API access to create items', async ({ page, context }) => {
			await loginAsUser(context, memberData.email);
			await page.goto('/dashboard');

			const response = await makeAuthenticatedRequest(page, '/api/inventory/items', {
				method: 'POST',
				data: {
					name: 'Unauthorized Item',
					description: 'Should not be created',
					category_id: testCategoryId,
					container_id: testContainerId,
					quantity: 1,
					attributes: {
						condition: 'Good'
					}
				}
			});

			expect(response.success).toBe(false);
			expect(response.error).toContain('Unauthorized');
		});

		test('should allow admin full access to items', async ({ page, context }) => {
			await loginAsUser(context, adminData.email);
			await page.goto('/dashboard/inventory/items');

			// Should see create button
			await expect(page.getByRole('button', { name: /create item/i })).toBeVisible();

			// Should be able to create via API
			await page.goto('/dashboard');
			const response = await makeAuthenticatedRequest(page, '/api/inventory/items', {
				method: 'POST',
				data: {
					name: 'Admin Item',
					description: 'Created by admin',
					category_id: testCategoryId,
					container_id: testContainerId,
					quantity: 1,
					attributes: {
						condition: 'Good'
					}
				}
			});

			expect(response.success).toBe(true);
		});
	});

	test.describe('Item Search and Filtering', () => {
		test('should search items by name', async ({ page, context }) => {
			await loginAsUser(context, quartermasterData.email);
			
			const timestamp = Date.now();

			// Create test items
			await page.goto('/dashboard');
			await makeAuthenticatedRequest(page, '/api/inventory/items', {
				method: 'POST',
				data: {
					name: `Searchable Item ${timestamp}`,
					description: 'Item for search test',
					category_id: testCategoryId,
					container_id: testContainerId,
					quantity: 1,
					attributes: {
						condition: 'Good'
					}
				}
			});

			await makeAuthenticatedRequest(page, '/api/inventory/items', {
				method: 'POST',
				data: {
					name: `Other Item ${timestamp}`,
					description: 'Different item',
					category_id: testCategoryId,
					container_id: testContainerId,
					quantity: 1,
					attributes: {
						condition: 'Good'
					}
				}
			});

			// Navigate to items page
			await page.goto('/dashboard/inventory/items');

			// Search for specific item
			await page.getByPlaceholder(/search items/i).fill('Searchable');

			// Should show only matching item
			await expect(page.getByText(`Searchable Item ${timestamp}`)).toBeVisible();
			await expect(page.getByText(`Other Item ${timestamp}`)).not.toBeVisible();
		});

		test('should filter items by category', async ({ page, context }) => {
			await loginAsUser(context, quartermasterData.email);
			
			const timestamp = Date.now();

			// Create items in different categories
			await page.goto('/dashboard');
			await makeAuthenticatedRequest(page, '/api/inventory/items', {
				method: 'POST',
				data: {
					name: `Weapon Item ${timestamp}`,
					description: 'Item in weapons category',
					category_id: weaponsCategoryId,
					container_id: testContainerId,
					quantity: 1,
					attributes: {
						weaponType: 'Longsword',
						inMaintenance: false
					}
				}
			});

			await makeAuthenticatedRequest(page, '/api/inventory/items', {
				method: 'POST',
				data: {
					name: `Armor Item ${timestamp}`,
					description: 'Item in armor category',
					category_id: armorCategoryId,
					container_id: testContainerId,
					quantity: 1,
					attributes: {
						armorType: 'Mask',
						size: 'M'
					}
				}
			});

			// Navigate to items page
			await page.goto('/dashboard/inventory/items');

			// Filter by weapons category
			await page.getByRole('combobox', { name: /filter by category/i }).click();
			await page.getByText('Weapons').click();

			// Should show only weapon item
			await expect(page.getByText(`Weapon Item ${timestamp}`)).toBeVisible();
			await expect(page.getByText(`Armor Item ${timestamp}`)).not.toBeVisible();
		});

		test('should filter items by container', async ({ page, context }) => {
			await loginAsUser(context, quartermasterData.email);
			
			const timestamp = Date.now();

			// Create another container
			await page.goto('/dashboard');
			const container2Response = await makeAuthenticatedRequest(page, '/api/inventory/containers', {
				method: 'POST',
				data: {
					name: `Second Container ${timestamp}`,
					description: 'Second container for filtering test'
				}
			});

			// Create items in different containers
			await makeAuthenticatedRequest(page, '/api/inventory/items', {
				method: 'POST',
				data: {
					name: `Container1 Item ${timestamp}`,
					description: 'Item in first container',
					category_id: testCategoryId,
					container_id: testContainerId,
					quantity: 1,
					attributes: {
						condition: 'Good'
					}
				}
			});

			await makeAuthenticatedRequest(page, '/api/inventory/items', {
				method: 'POST',
				data: {
					name: `Container2 Item ${timestamp}`,
					description: 'Item in second container',
					category_id: testCategoryId,
					container_id: container2Response.container.id,
					quantity: 1,
					attributes: {
						condition: 'Good'
					}
				}
			});

			// Navigate to items page
			await page.goto('/dashboard/inventory/items');

			// Filter by second container
			await page.getByRole('combobox', { name: /filter by container/i }).click();
			await page.getByText(`Second Container ${timestamp}`).click();

			// Should show only item from second container
			await expect(page.getByText(`Container2 Item ${timestamp}`)).toBeVisible();
			await expect(page.getByText(`Container1 Item ${timestamp}`)).not.toBeVisible();
		});

		test('should filter items by status', async ({ page, context }) => {
			await loginAsUser(context, quartermasterData.email);
			
			const timestamp = Date.now();

			// Create items with different statuses
			await page.goto('/dashboard');
			await makeAuthenticatedRequest(page, '/api/inventory/items', {
				method: 'POST',
				data: {
					name: `Available Item ${timestamp}`,
					description: 'Available item',
					category_id: testCategoryId,
					container_id: testContainerId,
					quantity: 1,
					attributes: {
						condition: 'Good'
					}
				}
			});

			const maintenanceResponse = await makeAuthenticatedRequest(page, '/api/inventory/items', {
				method: 'POST',
				data: {
					name: `Maintenance Item ${timestamp}`,
					description: 'Item for maintenance',
					category_id: testCategoryId,
					container_id: testContainerId,
					quantity: 1,
					attributes: {
						condition: 'Good'
					}
				}
			});

			// Mark second item as out for maintenance
			await makeAuthenticatedRequest(page, `/api/inventory/items/${maintenanceResponse.item.id}/maintenance`, {
				method: 'POST',
				data: {
					status: 'out_for_maintenance',
					notes: 'Needs repair'
				}
			});

			// Navigate to items page
			await page.goto('/dashboard/inventory/items');

			// Filter by maintenance status
			await page.getByRole('combobox', { name: /filter by status/i }).click();
			await page.getByText('Out for Maintenance').click();

			// Should show only maintenance item
			await expect(page.getByText(`Maintenance Item ${timestamp}`)).toBeVisible();
			await expect(page.getByText(`Available Item ${timestamp}`)).not.toBeVisible();
		});
	});

	test.describe('Item History and Audit Trail', () => {
		test('should track item creation in history', async ({ page, context }) => {
			await loginAsUser(context, quartermasterData.email);
			
			const timestamp = Date.now();
			const itemName = `History Item ${timestamp}`;

			// Create item via API
			await page.goto('/dashboard');
			const createResponse = await makeAuthenticatedRequest(page, '/api/inventory/items', {
				method: 'POST',
				data: {
					name: itemName,
					description: 'Item for history testing',
					category_id: testCategoryId,
					container_id: testContainerId,
					quantity: 1,
					attributes: {
						condition: 'Good'
					}
				}
			});

			const itemId = createResponse.item.id;

			// Navigate to item detail page
			await page.goto(`/dashboard/inventory/items/${itemId}`);

			// Should show creation history
			await expect(page.getByText(/created/i)).toBeVisible();
			await expect(page.getByText(quartermasterData.first_name)).toBeVisible();
		});

		test('should track item updates in history', async ({ page, context }) => {
			await loginAsUser(context, quartermasterData.email);
			
			const timestamp = Date.now();
			const itemName = `Update History Item ${timestamp}`;

			// Create item via API
			await page.goto('/dashboard');
			const createResponse = await makeAuthenticatedRequest(page, '/api/inventory/items', {
				method: 'POST',
				data: {
					name: itemName,
					description: 'Original description',
					category_id: testCategoryId,
					container_id: testContainerId,
					quantity: 1,
					attributes: {
						condition: 'Good'
					}
				}
			});

			const itemId = createResponse.item.id;

			// Update item
			await makeAuthenticatedRequest(page, `/api/inventory/items/${itemId}`, {
				method: 'PUT',
				data: {
					description: 'Updated description',
					quantity: 2
				}
			});

			// Navigate to item detail page
			await page.goto(`/dashboard/inventory/items/${itemId}`);

			// Should show update history
			await expect(page.getByText(/updated/i)).toBeVisible();
			await expect(page.getByText(/quantity.*1.*2/i)).toBeVisible();
		});
	});
});