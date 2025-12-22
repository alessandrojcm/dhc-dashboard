# Superforms to Remote Functions Migration - Status Report

**Last Updated:** December 17, 2025

## Overview

This document tracks the progress of migrating forms from `sveltekit-superforms` to SvelteKit's native Remote Functions API. It includes completed work, current blockers, and recommended solutions.

---

## ✅ Successfully Completed

### 1. Settings Sheet Migration

**File:** `src/routes/dashboard/members/settings-sheet.svelte`

**Changes Made:**
- ✅ Created `src/routes/dashboard/members/data.remote.ts` with `updateMemberSettings` Remote Function
- ✅ Migrated component from superforms to Remote Functions API
- ✅ Replaced `Form.*` components with new `Field.*` components
- ✅ Updated `+page.server.ts` to remove `updateSettings` action
- ✅ Changed loader to return plain `insuranceFormLink` value instead of superform
- ✅ Updated `+page.svelte` to pass `initialValue` prop
- ✅ Implemented `onMount()` for form initialization
- ✅ Implemented `$effect()` for success handling

### 2. AttributeBuilder Component Refactored

**File:** `src/lib/components/inventory/AttributeBuilder.svelte`

**Changes Made:**
- ✅ Refactored to use callback-based API instead of superforms coupling
- ✅ New props: `attributes`, `onAttributesChange`, `issues`
- ✅ Uses manual update handlers for nested array data
- ✅ Hidden input serializes attributes as JSON for form submission
- ✅ No type errors

**New API Pattern:**
```svelte
<AttributeBuilder
  attributes={attributes}
  onAttributesChange={handleAttributesChange}
  issues={createCategory.fields.available_attributes.issues()}
/>
```

### 3. Inventory Category Forms

**Files:**
- ✅ `src/routes/dashboard/inventory/categories/create/+page.svelte`
- ✅ `src/routes/dashboard/inventory/categories/[id]/edit/+page.svelte`
- ✅ `src/routes/dashboard/inventory/categories/[id]/edit/+page.server.ts`
- ✅ `src/routes/dashboard/inventory/categories/data.remote.ts`

**Changes Made:**
- ✅ Created Remote Functions: `createCategory`, `updateCategory`, `deleteCategory`
- ✅ Migrated create form to use `Field.*` components
- ✅ Migrated edit form to use `Field.*` components
- ✅ Integrated refactored AttributeBuilder component
- ✅ Removed superforms actions from server files
- ✅ No type errors

### 4. Member Edit Form

**Files:**
- ✅ `src/routes/dashboard/members/[memberId]/+page.svelte`
- ✅ `src/routes/dashboard/members/[memberId]/+page.server.ts`
- ✅ `src/routes/dashboard/members/[memberId]/data.remote.ts`
- ✅ `src/lib/schemas/membersSignup.ts` (added `memberProfileClientSchema`)

**Changes Made:**
- ✅ Created client-compatible schema with string-based `dateOfBirth`
- ✅ Updated Remote Function to convert string to Date on server
- ✅ Migrated all 15+ form fields to `Field.*` components
- ✅ Replaced `dateProxy` with manual DatePicker integration
- ✅ Replaced superforms store access with `.value()` / `.set()` methods
- ✅ Removed superforms actions from server file
- ✅ No type errors

**Date Handling Pattern:**
```typescript
// Client schema uses string
dateOfBirth: v.pipe(v.string(), v.nonEmpty('Date of birth is required.'))

// Server converts to Date
const dateOfBirth = new Date(data.dateOfBirth);
```

---

### 5. Inventory Container Forms

**Files:**
- ✅ `src/routes/dashboard/inventory/containers/data.remote.ts`
- ✅ `src/routes/dashboard/inventory/containers/create/+page.svelte`
- ✅ `src/routes/dashboard/inventory/containers/create/+page.server.ts`
- ✅ `src/routes/dashboard/inventory/containers/[id]/edit/+page.svelte`
- ✅ `src/routes/dashboard/inventory/containers/[id]/edit/+page.server.ts`

**Changes Made:**
- ✅ Created Remote Functions: `createContainer`, `updateContainer`, `deleteContainer`
- ✅ Migrated create form to use `Field.*` components
- ✅ Migrated edit form to use `Field.*` components
- ✅ Hierarchical container selection preserved
- ✅ No type errors

### 6. Inventory Item Forms

**Files:**
- ✅ `src/routes/dashboard/inventory/items/data.remote.ts`
- ✅ `src/routes/dashboard/inventory/items/create/+page.svelte`
- ✅ `src/routes/dashboard/inventory/items/create/+page.server.ts`
- ✅ `src/routes/dashboard/inventory/items/[id]/+page.svelte`
- ✅ `src/routes/dashboard/inventory/items/[id]/+page.server.ts`

**Changes Made:**
- ✅ Created Remote Functions: `createItem`, `updateItem`
- ✅ Migrated create form with dynamic category attributes
- ✅ Migrated edit form with view/edit mode toggle
- ✅ Dynamic attributes handled via local state + hidden JSON input
- ✅ No type errors

---

## 🚧 Remaining Work (Out of Scope)

The following forms still use superforms but were not migrated as part of this task:

### Complex Forms (Separate Migration)
- `src/lib/components/workshop-form.svelte`
- `src/routes/dashboard/members/invite-drawer.svelte`
- `src/routes/dashboard/workshops/create/+page.server.ts`
- `src/routes/dashboard/workshops/[id]/edit/+page.server.ts`

### Public Signup Flow (Separate Migration)
- `src/routes/(public)/members/signup/[invitationId]/+page.server.ts`
- `src/routes/(public)/members/signup/[invitationId]/confirm-invitation.svelte`
- `src/routes/(public)/members/signup/[invitationId]/payment-form.svelte`

---

## 🔧 Resolved Blockers

### 1. AttributeBuilder Component (RESOLVED)

**Original Problem:** Component was tightly coupled to superforms with `SuperForm<CategorySchema>` type, `$formData` store pattern, and `Form.Field` for nested arrays.

**Solution Implemented:** Refactored to callback-based API:
- New props: `attributes: AttributeDefinition[]`, `onAttributesChange: (attrs) => void`, `issues: Array<{message: string}>`
- Manual update handlers for add/remove/update operations
- Hidden input with JSON serialization for form submission
- Works with any form system (Remote Functions, superforms, or plain forms)

### 2. Date Handling in Member Form (RESOLVED)

**Original Problem:** Remote Functions don't serialize `Date` objects. The member form used `dateProxy()` from superforms.

**Solution Implemented:**
- Created `memberProfileClientSchema` with string-based `dateOfBirth`
- Server-side conversion: `const dateOfBirth = new Date(data.dateOfBirth)`
- DatePicker integration with `dayjs().format('YYYY-MM-DD')` for value setting

---

## 📋 Migration Patterns Reference

### Pattern: Nested Array Fields (AttributeBuilder)
```svelte
<script>
  // Get current value reactively
  const attributes = $derived(
    (form.fields.available_attributes.value() as AttributeDefinition[]) ?? []
  );

  // Callback to update
  const handleAttributesChange = (newAttributes: AttributeDefinition[]) => {
    form.fields.available_attributes.set(newAttributes);
  };
</script>

<AttributeBuilder
  attributes={attributes}
  onAttributesChange={handleAttributesChange}
  issues={form.fields.available_attributes.issues()}
/>
```

### Pattern: Date Fields (String-based)
```typescript
// Client schema
export const memberProfileClientSchema = v.object({
  dateOfBirth: v.pipe(v.string(), v.nonEmpty('Date of birth is required.'))
});

// Server handler
const dateOfBirth = new Date(data.dateOfBirth);
await service.update({ dateOfBirth });
```

### Pattern: Select Fields (Single/Multiple)
```svelte
<Select.Root
  type="single"
  value={gender}
  onValueChange={(v) => updateProfile.fields.gender.set(v)}
  name="gender"
>
  <!-- ... -->
</Select.Root>
```

---

## 🎯 Next Steps for Remaining Migrations

When migrating the remaining forms, follow these patterns:

1. **Create client schema** if Date fields exist (use string representation)
2. **Create `data.remote.ts`** with Remote Function
3. **Update `+page.server.ts`** to return plain data, remove actions
4. **Update component** to use `Field.*` components and `.value()` / `.set()` methods
5. **Test** form submission and validation

---

## 📝 Notes & Lessons Learned

### What Worked Well
- Settings sheet migration was straightforward
- Remote Functions API is cleaner than superforms for simple forms
- Field component provides good accessibility out of the box
- Progressive enhancement works automatically
- Callback-based component API works well for complex nested data

### Challenges Encountered & Solutions
- **Nested array field access:** Solved with callback-based component API
- **Two-way binding:** Use `.value()` / `.set()` methods with `oninput` handlers
- **Complex components tightly coupled to superforms:** Refactor to accept props + callbacks
- **Date type serialization:** Use string representation in client schema, convert on server

### Best Practices Identified
1. Use `onMount()` to initialize form fields with existing data
2. Use `$effect()` for side effects (toasts, navigation)
3. Use `{@const fieldProps = form.fields.name.as('type')}` pattern
4. Keep validation schemas in service layer for reuse
5. Create client-compatible schemas for Remote Functions (strings for dates)
6. Use callback-based APIs for reusable form components

---

## 🔗 Related Files

- **Migration Strategy:** `instructions/superforms_migration/COMPLETE_MIGRATION_STRATEGY.md`
- **Step 4 Instructions:** `instructions/superforms_migration/04_migrate_settings_forms.md`
- **Completed Examples:**
  - `src/routes/dashboard/members/settings-sheet.svelte`
  - `src/routes/dashboard/members/[memberId]/+page.svelte`
  - `src/routes/dashboard/inventory/categories/create/+page.svelte`
  - `src/routes/dashboard/inventory/categories/[id]/edit/+page.svelte`
- **Refactored Component:** `src/lib/components/inventory/AttributeBuilder.svelte`
