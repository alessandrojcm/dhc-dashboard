# Complete Migration Strategy: Superforms → Remote Functions

**Date:** December 17, 2025  
**Option:** Option 1 (Complete Migration)

## Executive Summary

Based on analysis of the blockers and SvelteKit Remote Functions documentation, **full migration is viable**. The key insight is that Remote Functions **do support nested arrays and objects** via indexed access (`fields.array[0].property`).

---

## Blocker Analysis & Solutions

### Blocker 1: AttributeBuilder Component

**Problem:** Component uses superforms store pattern (`$formData`) and `Form.Field` for nested arrays.

**Solution:** Remote Functions support nested field access:
```typescript
// Nested object
form.fields.info.height.as('number')

// Array indexing  
form.fields.attributes[0].as('text')

// Nested array of objects
form.fields.available_attributes[0].label.as('text')
```

**Implementation:**
1. Change prop type from `SuperForm<CategorySchema>` to the Remote Function type
2. Replace `$formData.available_attributes` with `form.fields.available_attributes.value()`
3. Replace `Form.Field` with `Field.Field` components
4. Use manual `oninput` handlers with `.set()` for updates

### Blocker 2: Date Handling in Member Form

**Problem:** Remote Functions don't serialize `Date` objects. The member form uses `dateProxy()`.

**Solution:** Use ISO string representation:
1. Create a client schema with `dateOfBirth: v.string()` (ISO format)
2. Transform to `Date` on server before validation/storage
3. Use standard date input with string value

**Implementation:**
```typescript
// Client schema (for Remote Functions)
export const memberProfileClientSchema = v.object({
  // ... other fields
  dateOfBirth: v.pipe(
    v.string(),
    v.nonEmpty('Date of birth is required.'),
    v.check((input) => {
      const date = new Date(input);
      return !isNaN(date.getTime());
    }, 'Invalid date')
  )
});

// Server-side: transform string to Date before service call
const dateOfBirth = new Date(data.dateOfBirth);
```

---

## Migration Order

### Phase 1: AttributeBuilder Refactor
1. Update `AttributeBuilder.svelte` to accept Remote Function form
2. Replace store access with `.value()` / `.set()` methods
3. Replace `Form.Field` with `Field.Field` components
4. Ensure type safety (no `any` types)

### Phase 2: Inventory Forms (Type Safety Only)
1. Fix category create form to work with refactored AttributeBuilder
2. Ensure no TypeScript errors
3. Skip edit/delete forms for now (WIP feature)

### Phase 3: Member Edit Form
1. Create client schema with string-based date
2. Create `data.remote.ts` with `updateProfile` function
3. Migrate form component from superforms to Remote Functions
4. Handle Date conversion on server side
5. Update `+page.server.ts` to remove actions

### Phase 4: Cleanup
1. Remove `sveltekit-superforms` from package.json
2. Remove `formsnap` from package.json
3. Delete old `Form.*` components if unused elsewhere
4. Update any remaining imports

---

## Technical Patterns

### Pattern: Array Field Updates
```svelte
<script>
  import { createCategory } from '../data.remote';
  
  // Get current array value
  const attributes = $derived(createCategory.fields.available_attributes.value() ?? []);
  
  function addAttribute(attr) {
    createCategory.fields.available_attributes.set([...attributes, attr]);
  }
  
  function updateAttribute(index, field, value) {
    const updated = [...attributes];
    updated[index] = { ...updated[index], [field]: value };
    createCategory.fields.available_attributes.set(updated);
  }
  
  function removeAttribute(index) {
    createCategory.fields.available_attributes.set(
      attributes.filter((_, i) => i !== index)
    );
  }
</script>
```

### Pattern: Nested Array Field Input
```svelte
{#each attributes as attr, index}
  <Field.Field>
    <Field.Label>Label</Field.Label>
    <Input
      value={attr.label}
      oninput={(e) => updateAttribute(index, 'label', e.currentTarget.value)}
      name={`available_attributes[${index}].label`}
    />
  </Field.Field>
{/each}
```

### Pattern: Date Field (String-based)
```svelte
<script>
  import { updateProfile } from './data.remote';
  
  // Initialize with ISO string from server data
  onMount(() => {
    updateProfile.fields.set({
      dateOfBirth: data.member.date_of_birth ?? ''
    });
  });
</script>

<Field.Field>
  {@const fieldProps = updateProfile.fields.dateOfBirth.as('date')}
  <Field.Label>Date of Birth</Field.Label>
  <input type="date" {...fieldProps} />
</Field.Field>
```

---

## Files to Modify

### AttributeBuilder
- `src/lib/components/inventory/AttributeBuilder.svelte`

### Inventory (Type Safety)
- `src/routes/dashboard/inventory/categories/create/+page.svelte`
- `src/routes/dashboard/inventory/categories/data.remote.ts` (already exists)

### Member Edit Form
- `src/routes/dashboard/members/[memberId]/data.remote.ts` (already exists, needs update)
- `src/routes/dashboard/members/[memberId]/+page.svelte`
- `src/routes/dashboard/members/[memberId]/+page.server.ts`
- `src/lib/schemas/membersSignup.ts` (add client schema)

---

## Estimated Effort

| Task | Time |
|------|------|
| AttributeBuilder refactor | 1-2 hours |
| Inventory type fixes | 30 min |
| Member form migration | 2-3 hours |
| Cleanup & testing | 1 hour |
| **Total** | **5-7 hours** |
