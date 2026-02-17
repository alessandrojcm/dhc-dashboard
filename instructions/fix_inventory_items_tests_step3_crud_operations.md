# Fix Inventory Items Tests - Step 3: CRUD Operations and API Replacement

## Context

This step replaces all remaining API-based CRUD operations with proper UI interactions. Many tests still try to use `/api/inventory/items` endpoints that don't exist. This step converts those to use actual UI interactions and page actions.

## Prerequisites

- Steps 1 and 2 must be completed first
- Understanding of how SvelteKit page actions work
- Familiarity with the application's UI patterns for CRUD operations

## Key Files to Reference

- `src/routes/dashboard/inventory/items/[id]/+page.svelte` - Item detail page with actions
- `src/routes/dashboard/inventory/items/+page.svelte` - Items listing page
- Any edit/delete page server files in the items directory
- `e2e/inventory-categories.spec.ts` - Reference for deletion patterns

## Current Issues

### 1. API-Based Item Creation in Tests

Many tests use `makeAuthenticatedRequest(page, '/api/inventory/items', {...})` which doesn't exist.

### 2. API-Based Updates and Deletions

Tests try to update/delete items via API instead of UI interactions.

### 3. Status Management via API

Maintenance status changes use non-existent `/api/inventory/items/{id}/maintenance` endpoints.

## Tasks to Complete

### 1. Replace API-Based Item Creation in Test Setup

**Current pattern in many tests:**

```typescript
const createResponse = await makeAuthenticatedRequest(page, '/api/inventory/items', {
  method: 'POST',
  data: {...}
});
const itemId = createResponse.item.id;
```

**Replace with UI-based creation:**

```typescript
// Navigate to create page
await page.goto('/dashboard/inventory/items');
await page.getByRole('link', { name: /add item/i }).click();

// Fill and submit form (using patterns from Steps 1 & 2)
await page.getByLabel(/quantity/i).fill('1');
await page.getByLabel(/category/i).click();
await page.getByText('Test Category').click();
await page.getByLabel(/container/i).click();
await page.getByText('Test Container').click();
await page.getByLabel(/condition/i).click();
await page.getByText('Good').click();

await page.getByRole('button', { name: /create item/i }).click();

// Extract item ID from redirect URL
await page.waitForURL(/\/dashboard\/inventory\/items\/[a-f0-9-]+$/);
const itemId = page.url().split('/').pop();
```

### 2. Fix Item Deletion Test

**Update "should delete item" test (around line 297):**

**Current approach**: Creates item via UI, then tries to delete via API.

**Fixed approach:**

```typescript
// After creating item via UI...

// Navigate back to items list to find the item
await page.goto('/dashboard/inventory/items');

// Find the item and click to view details
await page.getByText(itemName).click();

// Look for delete button in item detail page
// Check the actual markup in [id]/+page.svelte for delete button location
await page.getByRole('button', { name: /delete/i }).click();

// Handle confirmation dialog if it exists
await page.getByRole('button', { name: /confirm/i }).click();

// Should redirect to items list
await expect(page).toHaveURL('/dashboard/inventory/items');

// Verify item no longer appears
await expect(page.getByText(itemName)).not.toBeVisible();
```

### 3. Fix All API-Based Tests in "Item API Endpoints" Section

**The entire section starting around line 373 needs replacement.**

These tests should be converted to UI interaction tests or removed entirely since the app doesn't use API endpoints:

**Current tests to replace/remove:**

- "should create item via API as quartermaster" (line ~374)
- "should update item via API" (line ~403)
- "should delete item via API" (line ~448)
- "should validate required attributes" (line ~479) - Convert to UI validation test
- "should reject invalid attribute values" (line ~505) - Convert to UI validation test
- "should reject invalid data" (line ~531) - Convert to UI validation test

**Conversion approach:**

```typescript
// Instead of API test like this:
test('should create item via API as quartermaster', async ({ page, context }) => {
  const response = await makeAuthenticatedRequest(page, '/api/inventory/items', {...});
  expect(response.success).toBe(true);
});

// Convert to UI test like this:
test('should create item via UI as quartermaster', async ({ page, context }) => {
  await loginAsUser(context, quartermasterData.email);
  await page.goto('/dashboard/inventory/items');

  // Use UI creation pattern from previous steps
  await page.getByRole('link', { name: /add item/i }).click();
  // ... fill form ...
  await page.getByRole('button', { name: /create item/i }).click();

  // Verify success via UI
  await expect(page).toHaveURL(/\/dashboard\/inventory\/items\/[a-f0-9-]+$/);
  await expect(page.getByText(itemData.name)).toBeVisible(); // Or whatever display name pattern
});
```

### 4. Fix Maintenance Status Management

**Update "Item Status Management" section (around line 555):**

**Current issue**: Tests use `/api/inventory/items/{id}/maintenance` endpoints.

**Fixed approach:**

```typescript
// Instead of API call:
const maintenanceResponse = await makeAuthenticatedRequest(
	page,
	`/api/inventory/items/${itemId}/maintenance`,
	{
		method: 'POST',
		data: { status: 'out_for_maintenance', notes: 'Needs blade sharpening' }
	}
);

// Use UI interaction:
// First, find how maintenance status is toggled in the UI
// Check the item detail page for maintenance toggle functionality

// Navigate to item detail page
await page.goto(`/dashboard/inventory/items/${itemId}`);

// Look for maintenance toggle (could be button, checkbox, etc.)
// Based on the create form, there's a "Out for maintenance" checkbox
// The detail page might have similar controls

// If there's an edit button that leads to edit form:
await page.getByRole('button', { name: /edit item/i }).click();
await page.getByLabel(/out for maintenance/i).check();
await page.getByRole('button', { name: /update item/i }).click();

// Or if there's a direct toggle on detail page:
await page.getByRole('button', { name: /mark for maintenance/i }).click();

// Verify status change
await expect(page.getByText(/out for maintenance/i)).toBeVisible();
```

### 5. Update History Tracking Tests

**Update "Item History and Audit Trail" section (around line 924):**

**Current issue**: These tests assume history tracking exists and is accessible.

**Check if history functionality exists:**

1. Look at item detail page markup to see if history is displayed
2. Check if there are actual history tables/queries in the database schema
3. If history doesn't exist, remove these tests

**If history exists, fix pattern:**

```typescript
// Instead of API creation + history check:
const createResponse = await makeAuthenticatedRequest(page, '/api/inventory/items', {...});
const itemId = createResponse.item.id;
await page.goto(`/dashboard/inventory/items/${itemId}`);
await expect(page.getByText(/created/i)).toBeVisible();

// Use UI creation + history check:
// Create via UI (using established pattern)...
// Then check history section on detail page
await expect(page.getByText(/created/i)).toBeVisible();
await expect(page.getByText(quartermasterData.first_name)).toBeVisible();
```

### 6. Clean Up Helper Functions

**Remove or update the `makeAuthenticatedRequest` function usage:**

- Remove all calls to this function for item operations
- Keep only if needed for test data setup (categories, containers)
- Ensure consistent UI interaction patterns throughout

## Test Sections to Update

1. **Item CRUD Operations** (lines 164-371)
   - Keep "create basic item" and "create complex item" (fixed in Steps 1&2)
   - Fix "edit item and update attributes"
   - Fix "delete item"
   - Fix "update item quantity"

2. **Item API Endpoints** (lines 373-553)
   - **Remove entire section** or convert to equivalent UI tests
   - These tests assume API endpoints that don't exist

3. **Item Status Management** (lines 555-638)
   - Convert to UI-based maintenance status changes
   - Remove API calls, use form interactions or buttons

4. **Item History and Audit Trail** (lines 924-997)
   - Verify if history functionality exists in UI
   - If not, remove these tests
   - If yes, fix to use UI navigation instead of API

## Success Criteria

After this step:

1. No API endpoint calls remain for item CRUD operations
2. All item operations use proper UI interactions
3. Maintenance status changes work through UI
4. Deletion works through UI confirmation flow
5. Tests either work with existing history functionality or are removed

## Testing Strategy

Test each section individually:

```bash
# Test basic CRUD operations
pnpm test:e2e -- inventory-items --grep "create basic item"
pnpm test:e2e -- inventory-items --grep "delete item"

# Test status management
pnpm test:e2e -- inventory-items --grep "maintenance"

# Test full suite
pnpm test:e2e -- inventory-items
```

## Next Steps

Step 4 will focus on search and filtering functionality to match the actual UI components and behavior.
