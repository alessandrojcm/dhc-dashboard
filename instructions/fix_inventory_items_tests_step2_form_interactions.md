# Fix Inventory Items Tests - Step 2: Form Field Interactions and Validation

## Context

This step focuses on fixing form field interactions, validation tests, and ensuring all form elements match the actual UI implementation. This builds on Step 1 which fixed the basic navigation and creation pattern.

## Prerequisites

- Step 1 must be completed first
- Understanding of the actual form structure in `src/routes/dashboard/inventory/items/create/+page.svelte`
- Familiarity with SvelteKit SuperForm patterns used in the application

## Key Files to Reference

- `src/routes/dashboard/inventory/items/create/+page.svelte` - Creation form UI
- `src/routes/dashboard/inventory/items/[id]/edit/+page.svelte` - Edit form UI (if exists)
- `src/lib/components/inventory/DynamicAttributeFields.svelte` - Dynamic attributes component
- `src/lib/schemas/inventory.ts` - Validation schemas
- `e2e/inventory-categories.spec.ts` - Reference for form interaction patterns

## Form Structure Analysis

Based on the actual form structure, here's what needs to be fixed:

### Basic Form Fields

The create form has these key sections:

1. **Item Information Card**: Category, Container, Quantity, Maintenance checkbox, Notes
2. **Dynamic Attributes Card**: Category-specific attributes (conditionally shown)

### Field Types and Selectors

1. **Category Selection**: Select component with dropdown
2. **Container Selection**: Select component with hierarchical display
3. **Quantity**: Number input
4. **Out for Maintenance**: Checkbox
5. **Notes**: Textarea
6. **Dynamic Attributes**: Various input types based on category schema

## Tasks to Complete

### 1. Fix Complex Attribute Handling

**Current Issue**: Tests assume simple text inputs for attributes.

**Fix the "should create item with complex attributes" test (around line 202):**

```typescript
// Current (wrong):
await page.getByLabel(/weapon type/i).click();
await page.getByText('Longsword').click();

// Should be (for Select-type attributes):
await page.getByLabel(/weapon type/i).click();
await page.getByText('Longsword').click(); // This part is likely correct

// For text attributes:
await page.getByLabel(/manufacturer/i).fill('Albion Swords');

// For number attributes:
await page.getByLabel(/weight/i).fill('1.5');

// For boolean attributes:
await page.getByLabel(/in maintenance/i).check();
```

**Key considerations:**

- Dynamic attributes are only shown after category is selected
- Different attribute types have different interaction patterns
- Required attributes must be filled before form can be submitted

### 2. Fix Item Editing Tests

**Update the "should edit item and update attributes" test (around line 245):**

**Current issue**: Uses API to create item, then tries to navigate to edit page.

**Fix pattern:**

```typescript
// After creating item via UI (not API), get the item ID from URL
const itemId = page.url().split('/').pop();

// Navigate to edit page
await page.goto(`/dashboard/inventory/items/${itemId}/edit`);

// Update form fields using same selectors as create form
await page.getByLabel(/name/i).fill(updatedName); // This field may not exist!
await page.getByLabel(/description/i).fill('Updated description'); // This field may not exist!
await page.getByLabel(/quantity/i).fill('7');

// Submit form
await page.getByRole('button', { name: /update item/i }).click();
```

**Important**: Check if name/description fields actually exist in the edit form!

### 3. Fix Quantity Update Test

**Update the "should update item quantity" test (around line 332):**

**Current issue**: Assumes a separate "edit quantity" button exists.

**Fix pattern:**

```typescript
// Navigate to item detail page first
await page.goto('/dashboard/inventory/items');
await page.getByText(itemName).click(); // Go to detail view

// Look for edit button or quantity update mechanism in the UI
// Based on the detail page markup, this might be:
await page.getByRole('button', { name: /edit item/i }).click();

// Or there might be an inline quantity editor
// Check the actual detail page implementation
```

### 4. Fix Form Validation Tests

**Update validation tests to work with actual form validation:**

```typescript
// Test should submit form and check for validation errors
await page.getByRole('button', { name: /create item/i }).click();

// Look for actual validation error messages
// These will appear based on the SuperForm validation
await expect(page.getByText(/required/i)).toBeVisible();
// Or check for the specific error styling classes
```

### 5. Fix Attribute Validation

**For the "should validate required attributes" test (around line 479):**

**Current issue**: Tries to make API call with missing required attributes.

**Fix pattern:**

```typescript
// Create item via UI with missing required attributes
await page.goto('/dashboard/inventory/items/create');

// Fill basic required fields
await page.getByLabel(/quantity/i).fill('1');

// Select category that has required attributes
await page.getByLabel(/category/i).click();
await page.getByText('Test Category').click(); // Category with required 'condition'

// Select container
await page.getByLabel(/container/i).click();
await page.getByText('Test Container').click();

// DON'T fill required attributes - leave 'condition' empty

// Try to submit
await page.getByRole('button', { name: /create item/i }).click();

// Should show validation error
await expect(page.getByText(/condition.*required/i)).toBeVisible();
```

### 6. Fix Attribute Options Validation

**For the "should reject invalid attribute values" test (around line 505):**

```typescript
// Fill form with invalid select option
await page.goto('/dashboard/inventory/items/create');

// Fill basic fields
await page.getByLabel(/quantity/i).fill('1');
await page.getByLabel(/category/i).click();
await page.getByText('Test Category').click();
await page.getByLabel(/container/i).click();
await page.getByText('Test Container').click();

// Try to enter invalid option (this might not be possible in UI)
// Select components typically prevent invalid values
// May need to test this differently or remove this test
```

## Special Considerations

### Dynamic Attributes Behavior

- Attributes only appear after category selection
- Different attribute types require different interaction patterns:
  - **text**: `.fill(value)`
  - **number**: `.fill(stringValue)`
  - **select**: `.click()` then select option
  - **boolean**: `.check()` or `.uncheck()`

### Form State Management

- The form uses Svelte 5 reactive patterns
- Form validation happens on submission
- Success redirects to item detail page
- Errors are shown inline with field styling

### Navigation Flow

- Create: Items list → Create page → Item detail page (on success)
- Edit: Item detail → Edit page → Item detail page (on success)
- The edit page may redirect back to items list instead of detail

## Tests to Update in This Step

1. "should create item with complex attributes" (line ~202)
2. "should edit item and update attributes" (line ~245)
3. "should update item quantity" (line ~332)
4. "should validate required attributes" (line ~479)
5. "should reject invalid attribute values" (line ~505)
6. "should reject invalid data" (line ~531)

## Success Criteria

After this step:

1. All form field interactions use correct selectors
2. Dynamic attribute handling works properly
3. Form validation tests work with actual UI validation
4. Edit and update operations work through UI
5. No remaining API endpoint calls for basic CRUD operations

## Testing Commands

Run specific tests to verify fixes:

```bash
pnpm test:e2e -- inventory-items --grep "create item with complex attributes"
pnpm test:e2e -- inventory-items --grep "edit item"
pnpm test:e2e -- inventory-items --grep "validate"
```

## Next Steps

Step 3 will focus on replacing remaining API-based operations (maintenance status, deletion) with UI interactions.
