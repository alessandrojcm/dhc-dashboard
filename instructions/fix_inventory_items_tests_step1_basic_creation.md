# Fix Inventory Items Tests - Step 1: Basic Item Creation Pattern

## Context

The `e2e/inventory-items.spec.ts` test file is using non-existent REST API endpoints (`/api/inventory/items`) when the application actually uses SvelteKit page actions and form-based interactions. This step fixes the basic item creation test pattern to match the actual UI implementation.

## Current Issue

Tests are trying to call `/api/inventory/items` API endpoints that don't exist. The inventory system uses page actions on SvelteKit forms instead of dedicated API routes.

**Example of Wrong Pattern (current):**

```typescript
await page.getByRole('button', { name: /create item/i }).click();
const response = await makeAuthenticatedRequest(page, '/api/inventory/items', {...});
```

**Example of Correct Pattern (needed):**

```typescript
await page.getByRole('link', { name: /add item/i }).click();
// Fill form and submit using page actions
```

## Reference Implementation

Check `e2e/inventory-categories.spec.ts` for the correct pattern of UI interactions instead of API calls.

## Key Files to Examine

Before starting, examine these files to understand the actual UI:

- `src/routes/dashboard/inventory/items/+page.svelte` - Main items listing page
- `src/routes/dashboard/inventory/items/create/+page.svelte` - Item creation form
- `src/routes/dashboard/inventory/items/create/+page.server.ts` - Page action for creation
- `e2e/inventory-categories.spec.ts` - Working reference test

## Tasks to Complete

### 1. Fix Item Creation Navigation

**Current (wrong):**

```typescript
await page.getByRole('button', { name: /create item/i }).click();
```

**Should be:**

```typescript
await page.getByRole('link', { name: /add item/i }).click(); // Based on actual markup
```

**Location:** Around line 173 in the "should create basic item as quartermaster" test

### 2. Fix Form Field Selectors

Based on `src/routes/dashboard/inventory/items/create/+page.svelte`, update these selectors:

**Category Selection:**

```typescript
// Current (wrong):
await page.getByLabel(/category/i).click();
await page.getByText('Test Category').click();

// Should be (matches actual Select component):
await page.getByLabel(/category/i).click();
await page.getByText('Test Category').click(); // This part is correct
```

**Container Selection:**

```typescript
// Current (wrong):
await page.getByLabel(/container/i).click();
await page.getByText('Test Container').click();

// Should be (matches actual Select component):
await page.getByLabel(/container/i).click();
await page.getByText('Test Container').click(); // This part is correct
```

**Required Attributes:**
The condition field should work as-is since it uses the same Select pattern.

### 3. Fix Form Submission and Response Handling

**Current (wrong):**

```typescript
await page.getByRole('button', { name: /create/i }).click();
await expect(page.getByText(/item created successfully/i)).toBeVisible();
await expect(page.getByText(itemName)).toBeVisible();
```

**Should be:**

```typescript
await page.getByRole('button', { name: /create item/i }).click(); // Match exact button text
// Form submission redirects to item detail page, not items list
await expect(page).toHaveURL(new RegExp(`/dashboard/inventory/items/[a-f0-9-]+$`));
```

### 4. Fix Item Name Handling

The `getItemDisplayName` function in the UI may not show the simple name. Update expectations:

**Current:**

```typescript
await expect(page.getByText(itemName)).toBeVisible();
```

**Should be:**
Check the actual display logic in the UI component and update accordingly. The display might show category name + ID suffix instead.

### 5. Update Test Data Setup

Fix the beforeAll setup to use proper test data creation:

**Current (wrong - uses fake API calls):**

```typescript
const containerResponse = await page.request.fetch('/api/inventory/containers', {...});
```

**Should be (use direct database creation like inventory-containers.spec.ts):**

```typescript
// Use the pattern from inventory-containers.spec.ts
const supabaseServiceClient = getSupabaseServiceClient();
const { data: containerData } = await supabaseServiceClient
  .from('containers')
  .insert({...})
  .select()
  .single();
```

## Tests to Fix in This Step

Focus on these specific test cases:

1. "should create basic item as quartermaster" (around line 165)
2. "should create item with complex attributes" (around line 202)

## Success Criteria

After this step:

1. Item creation tests navigate to the correct create page
2. Form fields are filled using correct selectors
3. Form submission works and redirects properly
4. No API endpoint calls are made
5. Tests use proper UI interaction patterns

## Next Steps

This step focuses only on basic item creation. Editing, deletion, and API-based operations will be handled in subsequent steps.

## Implementation Notes

- Import the supabase service client from setupFunctions if needed for test data
- Follow the exact same pattern used in inventory-categories.spec.ts
- Test with `pnpm test:e2e -- inventory-items` to verify fixes
- Ensure all three services are running (supabase:start, supabase:functions:serve, dev)
