# Fix Inventory Items Tests - Step 4: Search and Filtering Functionality

## Context

This step fixes the search and filtering tests to match the actual UI implementation. The current tests assume incorrect selectors and filtering mechanisms that don't match the actual filter components implemented in the items page.

## Prerequisites

- Steps 1, 2, and 3 must be completed first
- Understanding of the actual filter UI in `/dashboard/inventory/items`
- Familiarity with how URL-based filtering works in SvelteKit

## Key Files to Reference

- `src/routes/dashboard/inventory/items/+page.svelte` - Main items page with filters
- `src/routes/dashboard/inventory/items/+page.server.ts` - Server-side filtering logic
- Lines 68-150 in the items page show the actual filter implementation

## Current Issues

### 1. Incorrect Filter Component Selectors

Tests use generic selectors that don't match the actual Select components.

### 2. Wrong Search Input Selector

Tests use `getByPlaceholder(/search items/i)` but actual placeholder might be different.

### 3. Incorrect Filter Application

Tests assume immediate filtering, but the UI has "Apply" and "Clear" buttons.

### 4. Wrong Filter Value Patterns

Tests assume filter values work differently than the actual implementation.

## Actual Filter Implementation Analysis

Based on `+page.svelte` lines 68-150:

### Filter Structure

1. **Search Input**: Text input with search icon
2. **Category Filter**: Select dropdown with categories
3. **Container Filter**: Select dropdown with containers
4. **Maintenance Filter**: Select dropdown with status options
5. **Apply/Clear Buttons**: Buttons to apply or clear filters

### Filter Behavior

- Filters use URL parameters (`search`, `category`, `container`, `maintenance`)
- Apply button triggers navigation with new URL params
- Clear button resets all filters and navigates to base URL
- Filtering is server-side via page load function

## Tasks to Complete

### 1. Fix Search Input Selector and Behavior

**Current (wrong):**

```typescript
await page.getByPlaceholder(/search items/i).fill('Searchable');
// Missing filter application
```

**Fixed approach:**

```typescript
// Use correct placeholder text from actual markup (line 84)
await page.getByPlaceholder(/search items/i).fill('Searchable');

// Must click Apply button to trigger filter
await page.getByRole('button', { name: /apply/i }).click();

// Wait for navigation with new search params
await page.waitForURL(/\?.*search=Searchable/);
```

### 2. Fix Category Filter Interaction

**Current (wrong):**

```typescript
await page.getByRole('combobox', { name: /filter by category/i }).click();
await page.getByText('Weapons').click();
```

**Fixed approach:**

```typescript
// The actual implementation uses Select component with "Category" label
await page.getByLabel(/category/i).click(); // Based on line 92 label
await page.getByText('Weapons').click();

// Must apply filters
await page.getByRole('button', { name: /apply/i }).click();

// Wait for URL change
await page.waitForURL(/\?.*category=/);
```

### 3. Fix Container Filter Interaction

**Current (wrong):**

```typescript
await page.getByRole('combobox', { name: /filter by container/i }).click();
await page.getByText(`Second Container ${timestamp}`).click();
```

**Fixed approach:**

```typescript
// Use actual label from markup (line 107)
await page.getByLabel(/container/i).click();
await page.getByText(`Second Container ${timestamp}`).click();

// Apply filters
await page.getByRole('button', { name: /apply/i }).click();
```

### 4. Fix Maintenance Status Filter

**Current (wrong):**

```typescript
await page.getByRole('combobox', { name: /filter by status/i }).click();
await page.getByText('Out for Maintenance').click();
```

**Fixed approach:**

```typescript
// Use actual label from markup (line 122)
await page.getByLabel(/maintenance/i).click();
await page.getByText('Out for maintenance').click(); // Match exact option text from line 130

// Apply filters
await page.getByRole('button', { name: /apply/i }).click();
```

### 5. Fix Filter Clearing

**Add missing clear filter tests:**

```typescript
// After applying filters, test clearing
await page.getByRole('button', { name: /clear/i }).click();

// Should navigate back to base URL
await expect(page).toHaveURL('/dashboard/inventory/items');

// All items should be visible again
await expect(page.getByText(`Searchable Item ${timestamp}`)).toBeVisible();
await expect(page.getByText(`Other Item ${timestamp}`)).toBeVisible();
```

### 6. Update Test Data Creation for Filtering

**Fix the filtering test data setup:**

All filtering tests create items via API calls. Replace with UI-based creation or direct database inserts:

```typescript
// Instead of:
await makeAuthenticatedRequest(page, '/api/inventory/items', {...});

// Use UI creation (established pattern from previous steps) or:
// Use direct database insert for test data efficiency:
const supabaseServiceClient = getSupabaseServiceClient();
await supabaseServiceClient.from('inventory_items').insert({
  id: crypto.randomUUID(),
  category_id: weaponsCategoryId,
  container_id: testContainerId,
  quantity: 1,
  attributes: { weaponType: 'Longsword' },
  created_by: quartermasterData.userId
});
```

## Test Cases to Fix

### 1. "should search items by name" (around line 716)

**Issues to fix:**

- Replace API item creation with UI or database insert
- Fix search input selector
- Add filter application step
- Verify URL params change

### 2. "should filter items by category" (around line 762)

**Issues to fix:**

- Replace API item creation
- Fix category filter selector and interaction
- Add filter application
- Verify filtered results

### 3. "should filter items by container" (around line 811)

**Issues to fix:**

- Replace API container/item creation
- Fix container filter selector
- Add filter application step

### 4. "should filter items by status" (around line 867)

**Issues to fix:**

- Replace API item creation and status setting
- Fix status filter selector and option text
- Add filter application
- May need to create maintenance item via UI first

## Additional Test Improvements

### 1. Add Combined Filter Test

```typescript
test('should apply multiple filters simultaneously', async ({ page, context }) => {
	await loginAsUser(context, quartermasterData.email);

	// Create diverse test data...

	await page.goto('/dashboard/inventory/items');

	// Apply multiple filters
	await page.getByPlaceholder(/search items/i).fill('Weapon');
	await page.getByLabel(/category/i).click();
	await page.getByText('Weapons').click();
	await page.getByLabel(/maintenance/i).click();
	await page.getByText('Available items').click();

	await page.getByRole('button', { name: /apply/i }).click();

	// Verify URL has all params
	await expect(page).toHaveURL(/\?.*search=Weapon.*category=.*maintenance=/);

	// Verify results match all filters
	// ...
});
```

### 2. Add Filter Persistence Test

```typescript
test('should persist filters across navigation', async ({ page, context }) => {
	// Apply filters, navigate away, navigate back
	// Verify filters are still applied (URL-based persistence)
});
```

### 3. Add Filter Reset Test

```typescript
test('should reset all filters when clear button is clicked', async ({ page, context }) => {
	// Apply several filters
	// Click clear button
	// Verify all filters reset and URL is clean
});
```

## Success Criteria

After this step:

1. All filter interactions use correct selectors
2. Filter application requires clicking Apply button
3. Filter clearing works properly
4. Search functionality works with correct input selector
5. URL parameters change correctly when filters are applied
6. No API calls for test data creation in filter tests

## Testing Commands

Test filtering functionality:

```bash
# Test search
pnpm test:e2e -- inventory-items --grep "search items"

# Test category filtering
pnpm test:e2e -- inventory-items --grep "filter items by category"

# Test all filtering
pnpm test:e2e -- inventory-items --grep "filter"
```

## Edge Cases to Consider

1. **Empty Filter Results**: Test behavior when no items match filters
2. **Invalid Filter Values**: Ensure filters handle edge cases gracefully
3. **URL Parameter Handling**: Test direct URL access with filter params
4. **Filter State Reset**: Verify filters reset properly on page refresh

## Next Steps

Step 5 will address access control tests and cleanup any remaining issues with role-based functionality and test organization.
