# Fix Inventory Items Tests - Step 5: Access Control and Final Cleanup

## Context

This final step addresses access control tests, cleans up any remaining issues, and ensures the test suite is comprehensive and maintainable. It also removes any functionality tests for features that don't exist in the actual implementation.

## Prerequisites

- Steps 1, 2, 3, and 4 must be completed first
- Understanding of the application's role-based access control system
- Familiarity with the actual UI elements available to different user roles

## Key Files to Reference

- `src/lib/server/roles.ts` - Role definitions and permissions
- `src/routes/dashboard/inventory/items/+page.svelte` - Main items page UI
- `src/routes/dashboard/inventory/items/+layout.server.ts` - Authorization logic (if exists)
- `e2e/inventory-categories.spec.ts` - Reference for access control patterns

## Current Issues

### 1. Incorrect UI Element Visibility Assumptions

Tests assume certain buttons/elements are visible/hidden for different roles without checking actual implementation.

### 2. API-Based Access Control Tests

Some access control tests still use non-existent API endpoints.

### 3. Missing Role-Based UI Tests

Tests don't cover all the role-based UI differences properly.

### 4. Outdated Test Data and Cleanup Issues

Test data setup and cleanup may have issues from previous steps.

## Tasks to Complete

### 1. Fix Quartermaster Access Control Tests

**Update "should allow quartermaster full access to items" (around line 641):**

**Current approach:**

```typescript
await expect(page.getByRole('button', { name: /create item/i })).toBeVisible();
```

**Issues to verify and fix:**

- Check if the "create item" element is actually a button or a link
- Based on the main page markup (line 62-65), it's actually a link: `<Button href="/dashboard/inventory/items/create">`

**Fixed approach:**

```typescript
await loginAsUser(context, quartermasterData.email);
await page.goto('/dashboard/inventory/items');

// Should see the "Add Item" link (not button)
await expect(page.getByRole('link', { name: /add item/i })).toBeVisible();

// Should be able to access items page
await expect(page.getByRole('heading', { name: /inventory items/i })).toBeVisible();

// Should be able to access create page
await page.getByRole('link', { name: /add item/i }).click();
await expect(page).toHaveURL('/dashboard/inventory/items/create');
```

### 2. Fix Member Access Control Tests

**Update "should allow members read-only access to available items" (around line 652):**

**Current issues:**

- Assumes create button exists but should be hidden
- Doesn't properly test maintenance item visibility restrictions

**Fixed approach:**

```typescript
await loginAsUser(context, memberData.email);
await page.goto('/dashboard/inventory/items');

// Should be able to view items page
await expect(page.getByRole('heading', { name: /inventory items/i })).toBeVisible();

// Should NOT see the "Add Item" link
await expect(page.getByRole('link', { name: /add item/i })).not.toBeVisible();

// Should be able to see available items but not maintenance items
// (This requires creating test items with different statuses first)

// Create available item and maintenance item via database or previous user
// Then verify visibility as member
```

### 3. Fix API Access Control Tests

**Update "should deny member API access to create items" (around line 666):**

**Current issue:** Tests non-existent API endpoints.

**Two options:**

1. **Remove this test entirely** since there are no API endpoints
2. **Convert to UI access test**:

```typescript
test('should deny member access to create item page', async ({ page, context }) => {
	await loginAsUser(context, memberData.email);

	// Try to access create page directly
	await page.goto('/dashboard/inventory/items/create');

	// Should be redirected or show access denied
	// Check actual behavior - might redirect to login or show 403
	await expect(page).not.toHaveURL('/dashboard/inventory/items/create');
	// OR
	await expect(page.getByText(/not authorized/i)).toBeVisible();
});
```

### 4. Fix Admin Access Control Tests

**Update "should allow admin full access to items" (around line 688):**

**Similar fixes as quartermaster test:**

```typescript
await loginAsUser(context, adminData.email);
await page.goto('/dashboard/inventory/items');

// Should see "Add Item" link
await expect(page.getByRole('link', { name: /add item/i })).toBeVisible();

// Should be able to create items via UI (not API)
await page.getByRole('link', { name: /add item/i }).click();
await expect(page).toHaveURL('/dashboard/inventory/items/create');

// Fill and submit create form to verify full access
// ... use established creation pattern ...
```

### 5. Clean Up History and Audit Trail Tests

**Review "Item History and Audit Trail" section (around line 924):**

**Check if history functionality actually exists:**

1. Examine the item detail page (`[id]/+page.svelte`)
2. Look for history section in the UI
3. Check if there are database tables for audit trails

**Based on findings:**

**If history exists in UI:**

```typescript
// Keep tests but fix to use UI navigation instead of API
test('should track item creation in history', async ({ page, context }) => {
	await loginAsUser(context, quartermasterData.email);

	// Create item via UI (established pattern)
	// Navigate to item detail page
	// Check if history section shows creation event
	await expect(page.getByText(/created/i)).toBeVisible();
});
```

**If history doesn't exist:**

```typescript
// Remove the entire "Item History and Audit Trail" test section
// Add comment explaining why:
/*
 * History/audit trail functionality is not implemented in the current UI
 * These tests have been removed until the feature is implemented
 */
```

### 6. Fix Test Data Setup and Cleanup

**Review and fix the `beforeAll` setup (around line 16):**

**Current issues:**

- Uses fake API calls to create test data
- Complex setup that may not work properly

**Fixed approach:**

```typescript
test.beforeAll(async () => {
	const timestamp = Date.now();

	// Create users (this part is correct)
	quartermasterData = await createMember({
		email: `quartermaster-items-${timestamp}@test.com`,
		roles: new Set(['quartermaster'])
	});
	// ... other users

	// Use direct database creation for test data
	const supabaseServiceClient = getSupabaseServiceClient();

	// Create test container
	const { data: containerData } = await supabaseServiceClient
		.from('containers')
		.insert({
			id: crypto.randomUUID(),
			name: `Test Container ${timestamp}`,
			description: 'Container for test items',
			created_by: quartermasterData.userId
		})
		.select()
		.single();

	testContainerId = containerData.id;

	// Create test categories
	const { data: categoryData } = await supabaseServiceClient
		.from('equipment_categories')
		.insert({
			id: crypto.randomUUID(),
			name: `Test Category ${timestamp}`,
			description: 'Basic category for testing',
			available_attributes: {
				brand: { type: 'text', label: 'Brand', required: false },
				condition: {
					type: 'select',
					label: 'Condition',
					required: true,
					options: ['New', 'Good', 'Fair', 'Poor']
				}
			}
		})
		.select()
		.single();

	testCategoryId = categoryData.id;

	// Continue pattern for other test data...
});
```

### 7. Add Missing Role-Based Tests

**Add comprehensive role coverage:**

```typescript
test.describe('Role-based UI Elements', () => {
	test('should show different actions for different roles', async ({ page, context }) => {
		// Test quartermaster sees edit/delete actions
		await loginAsUser(context, quartermasterData.email);
		await page.goto('/dashboard/inventory/items');

		// Create an item first or use existing test item

		// Go to item detail page
		await page.getByText('Test Item').click();

		// Should see edit and delete actions
		await expect(page.getByRole('button', { name: /edit/i })).toBeVisible();
		await expect(page.getByRole('button', { name: /delete/i })).toBeVisible();

		// Test member sees only view actions
		await loginAsUser(context, memberData.email);
		await page.goto('/dashboard/inventory/items');

		// Same item should only show view action
		await page.getByText('Test Item').click();
		await expect(page.getByRole('button', { name: /edit/i })).not.toBeVisible();
		await expect(page.getByRole('button', { name: /delete/i })).not.toBeVisible();
	});
});
```

### 8. Remove Non-Functional Tests

**Remove or mark as skipped any tests for features that don't exist:**

1. **API Endpoint tests** - Remove entirely if no endpoints exist
2. **History tracking tests** - Remove if no history UI exists
3. **Advanced status management** - Remove if not implemented
4. **Complex maintenance workflows** - Remove if not implemented

**Use skip pattern for future features:**

```typescript
test.skip('should track detailed item history', async ({ page, context }) => {
	// This test is skipped because detailed history tracking is not yet implemented
	// TODO: Implement when history feature is added
});
```

## Final Cleanup Tasks

### 1. Consolidate Imports

Ensure all necessary imports are present and remove unused ones:

```typescript
import { expect, test } from '@playwright/test';
import { createMember, getSupabaseServiceClient } from './setupFunctions';
import { loginAsUser } from './supabaseLogin';
// Remove any unused imports
```

### 2. Standardize Test Structure

Ensure consistent test organization:

```typescript
test.describe('Inventory Items Management', () => {
	// Setup and cleanup

	test.describe('Item CRUD Operations', () => {
		// Basic create, read, update, delete
	});

	test.describe('Form Interactions and Validation', () => {
		// Form-specific tests
	});

	test.describe('Search and Filtering', () => {
		// Filter and search tests
	});

	test.describe('Access Control', () => {
		// Role-based access tests
	});

	// Remove: test.describe('Item API Endpoints')
	// Remove: test.describe('Item History and Audit Trail') - if not implemented
});
```

### 3. Update Test Documentation

Add clear comments explaining test coverage and any limitations.

## Success Criteria

After this step:

1. All access control tests work with actual UI elements
2. No API endpoint calls remain anywhere in the test file
3. Tests accurately reflect the role-based permissions in the app
4. Non-existent features are either removed or marked as skipped
5. Test data setup is reliable and uses proper database operations
6. Test structure is clean and maintainable

## Final Testing

Run the complete test suite to ensure everything works:

```bash
# Run all inventory items tests
pnpm test:e2e -- inventory-items

# Run with different roles
pnpm test:e2e -- inventory-items --grep "quartermaster"
pnpm test:e2e -- inventory-items --grep "member"
pnpm test:e2e -- inventory-items --grep "admin"

# Run specific sections
pnpm test:e2e -- inventory-items --grep "access control"
```

## Final Deliverable

A completely functional `e2e/inventory-items.spec.ts` file that:

- Uses only UI interactions (no API calls)
- Has proper selectors matching actual markup
- Tests role-based access correctly
- Provides good coverage of actual functionality
- Is maintainable and follows project patterns
- Runs successfully in CI/CD environment
