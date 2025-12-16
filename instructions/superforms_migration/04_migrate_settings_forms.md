# Step 4: Migrate Settings and CRUD Forms

## Objective

Migrate the simpler settings forms and inventory CRUD forms from superforms to Remote Functions. These forms follow similar patterns and can be migrated in batch.

## MCP Server Available

**IMPORTANT**: You have access to the Svelte MCP server. Use it to look up:
- SvelteKit Remote Functions `form()` documentation
- `getRequestEvent()` for platform access
- Redirect patterns after successful mutations

## Forms to Migrate

### Priority 1: Settings Forms
1. `src/routes/dashboard/members/settings-sheet.svelte`
2. `src/routes/dashboard/members/[memberId]/+page.svelte` (member edit form)

### Priority 2: Inventory CRUD Forms
3. `src/routes/dashboard/inventory/categories/create/+page.svelte`
4. `src/routes/dashboard/inventory/categories/[id]/edit/+page.svelte`
5. `src/routes/dashboard/inventory/containers/create/+page.svelte`
6. `src/routes/dashboard/inventory/containers/[id]/edit/+page.svelte`
7. `src/routes/dashboard/inventory/items/create/+page.svelte`
8. `src/routes/dashboard/inventory/items/[id]/+page.svelte`

## Pattern: Settings Sheet

### Current Implementation

`src/routes/dashboard/members/settings-sheet.svelte`:

```svelte
<script lang="ts">
  import { superForm, type SuperValidated } from 'sveltekit-superforms/client';
  import memberSettingsSchema from '$lib/schemas/membersSettings';
  import { valibotClient } from 'sveltekit-superforms/adapters';
  
  const props: {
    form: SuperValidated<MemberSettingsOutput, string, MemberSettingsOutput>;
  } = $props();
  
  const form = superForm(props.form, {
    resetForm: false,
    validators: valibotClient(memberSettingsSchema),
    onResult: ({ result }) => {
      if (result.type === 'error') toast.error(result.error.message);
      if (result.type === 'success') toast.success('Settings updated');
    }
  });
  
  const { form: formData, enhance, submitting } = form;
</script>

<form method="POST" action="?/updateSettings" use:enhance>
  <!-- fields -->
</form>
```

### New Implementation

Create `src/routes/dashboard/members/data.remote.ts`:

```typescript
import { form, getRequestEvent } from '$app/server';
import memberSettingsSchema from '$lib/schemas/membersSettings';
// Import your service layer

export const updateMemberSettings = form(
  memberSettingsSchema,
  async (data) => {
    const event = getRequestEvent();
    const { session } = await event.locals.safeGetSession();
    
    if (!session) {
      throw new Error('Unauthorized');
    }
    
    // Use your existing service layer
    // const settingsService = createSettingsService(event.platform!, session);
    // await settingsService.update(data);
    
    return { success: 'Settings updated successfully' };
  }
);
```

Update `settings-sheet.svelte`:

```svelte
<script lang="ts">
  import { updateMemberSettings } from './data.remote';
  import * as Sheet from '$lib/components/ui/sheet/index.js';
  import * as Form from '$lib/components/ui/form';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import { Lock } from 'lucide-svelte';
  import LoaderCircle from '$lib/components/ui/loader-circle.svelte';
  import { toast } from 'svelte-sonner';

  let isOpen = $state(false);
</script>

<Button variant="outline" class="fixed right-4 top-4" onclick={() => (isOpen = true)}>
  <Lock class="mr-2 h-4 w-4" />
  Settings
</Button>

<Sheet.Root bind:open={isOpen}>
  <Sheet.Content class="w-full">
    <Sheet.Header>
      <Sheet.Title>Settings</Sheet.Title>
      <Sheet.Description>Configure your members settings here.</Sheet.Description>
    </Sheet.Header>
    
    <form {...updateMemberSettings} class="space-y-4 mt-4 p-8">
      <Form.Field field={updateMemberSettings.fields.insuranceFormLink} label="HEMA Insurance Form Link">
        {#snippet children(field)}
          <Input
            {...field.as('url')}
            placeholder="https://example.com/insurance-form"
          />
        {/snippet}
      </Form.Field>
      
      <Button type="submit" class="w-full">
        Save Settings
      </Button>
    </form>
  </Sheet.Content>
</Sheet.Root>
```

## Pattern: Inventory Create Form

### Current Implementation

`src/routes/dashboard/inventory/categories/create/+page.svelte` uses superforms with:
- `superForm(data.form, { validators: valibot(schema) })`
- `use:enhance`
- `$formData` for field values

### New Implementation

Create `src/routes/dashboard/inventory/categories/data.remote.ts`:

```typescript
import { form, getRequestEvent } from '$app/server';
import { redirect } from '@sveltejs/kit';
import { CategoryCreateSchema } from '$lib/server/services/inventory';
// or import from your schemas location

export const createCategory = form(
  CategoryCreateSchema,
  async (data) => {
    const event = getRequestEvent();
    const { session } = await event.locals.safeGetSession();
    
    if (!session) {
      throw new Error('Unauthorized');
    }
    
    // Use your service layer
    const categoryService = createCategoryService(event.platform!, session);
    const category = await categoryService.create(data);
    
    // Redirect to the new category
    redirect(303, `/dashboard/inventory/categories/${category.id}`);
  }
);
```

Update `create/+page.svelte`:

```svelte
<script lang="ts">
  import { createCategory } from '../data.remote';
  import * as Form from '$lib/components/ui/form';
  import { Input } from '$lib/components/ui/input';
  import { Textarea } from '$lib/components/ui/textarea';
  import { Button } from '$lib/components/ui/button';
  import { Card, CardContent, CardHeader, CardTitle } from '$lib/components/ui/card';
</script>

<Card>
  <CardHeader>
    <CardTitle>Create Category</CardTitle>
  </CardHeader>
  <CardContent>
    <form {...createCategory} class="space-y-4">
      <Form.Field field={createCategory.fields.name} label="Name">
        {#snippet children(field)}
          <Input {...field.as('text')} placeholder="Category name" />
        {/snippet}
      </Form.Field>
      
      <Form.Field field={createCategory.fields.description} label="Description">
        {#snippet children(field)}
          <Textarea {...field.as('text')} placeholder="Category description" />
        {/snippet}
      </Form.Field>
      
      <div class="flex gap-2">
        <Button type="submit">Create</Button>
        <Button href="/dashboard/inventory/categories" variant="outline">Cancel</Button>
      </div>
    </form>
  </CardContent>
</Card>
```

## Pattern: Inventory Edit Form

### New Implementation

For edit forms, you need to populate initial values. Create `src/routes/dashboard/inventory/categories/[id]/data.remote.ts`:

```typescript
import { form, getRequestEvent } from '$app/server';
import { redirect, invalid } from '@sveltejs/kit';
import { CategoryUpdateSchema } from '$lib/server/services/inventory';

export const updateCategory = form(
  CategoryUpdateSchema,
  async (data, issue) => {
    const event = getRequestEvent();
    const { session } = await event.locals.safeGetSession();
    const categoryId = event.params.id;
    
    if (!session) {
      throw new Error('Unauthorized');
    }
    
    const categoryService = createCategoryService(event.platform!, session);
    
    try {
      await categoryService.update(categoryId, data);
    } catch (err) {
      if (err instanceof Error && err.message.includes('not found')) {
        throw new Error('Category not found');
      }
      throw err;
    }
    
    redirect(303, `/dashboard/inventory/categories/${categoryId}`);
  }
);

export const deleteCategory = form(
  {}, // Empty schema for delete
  async () => {
    const event = getRequestEvent();
    const { session } = await event.locals.safeGetSession();
    const categoryId = event.params.id;
    
    if (!session) {
      throw new Error('Unauthorized');
    }
    
    const categoryService = createCategoryService(event.platform!, session);
    await categoryService.delete(categoryId);
    
    redirect(303, '/dashboard/inventory/categories');
  }
);
```

For edit forms, the `+page.server.ts` still loads the existing data:

```typescript
// +page.server.ts
export const load = async ({ params, platform, locals }) => {
  const { session } = await locals.safeGetSession();
  const categoryService = createCategoryService(platform!, session);
  const category = await categoryService.findById(params.id);
  
  return { category };
};
```

The form uses `field.set()` to populate initial values:

```svelte
<script lang="ts">
  import { updateCategory, deleteCategory } from './data.remote';
  import { onMount } from 'svelte';
  
  let { data } = $props();
  
  // Populate form with existing data on mount
  onMount(() => {
    updateCategory.fields.set({
      name: data.category.name,
      description: data.category.description
    });
  });
</script>

<form {...updateCategory} class="space-y-4">
  <Form.Field field={updateCategory.fields.name} label="Name">
    {#snippet children(field)}
      <Input {...field.as('text')} />
    {/snippet}
  </Form.Field>
  
  <!-- ... other fields ... -->
  
  <div class="flex gap-2">
    <Button type="submit">Save</Button>
    <form {...deleteCategory}>
      <Button type="submit" variant="destructive">Delete</Button>
    </form>
  </div>
</form>
```

## Pattern: Items Create Form (Complex)

The items create form has dynamic attributes based on category selection. This requires:

1. Using `field.value()` to track category selection
2. Dynamically rendering attribute fields

```svelte
<script lang="ts">
  import { createItem } from '../data.remote';
  
  let { data } = $props();
  
  // Track selected category
  const selectedCategoryId = $derived(createItem.fields.category_id.value() as string);
  const selectedCategory = $derived(
    data.categories.find(c => c.id === selectedCategoryId)
  );
  const categoryAttributes = $derived(
    selectedCategory?.available_attributes ?? []
  );
</script>

<form {...createItem}>
  <!-- Category select -->
  <Form.Field field={createItem.fields.category_id} label="Category">
    {#snippet children(field)}
      <Select.Root 
        value={field.value() as string}
        onValueChange={(v) => {
          field.set(v);
          // Reset attributes when category changes
          createItem.fields.attributes.set({});
        }}
      >
        <!-- options -->
      </Select.Root>
    {/snippet}
  </Form.Field>
  
  <!-- Dynamic attributes -->
  {#if selectedCategory}
    {#each categoryAttributes as attr (attr.name)}
      <!-- Render attribute field based on attr.type -->
      {#if attr.type === 'text'}
        <Form.Field field={createItem.fields.attributes[attr.name]} label={attr.label}>
          {#snippet children(field)}
            <Input {...field.as('text')} />
          {/snippet}
        </Form.Field>
      {/if}
    {/each}
  {/if}
</form>
```

## Server Files to Update

For each form migrated, update the corresponding `+page.server.ts`:

1. **Remove** the `actions` export
2. **Keep** the `load` function if it loads non-form data
3. **Remove** superforms imports (`superValidate`, `message`, `setError`, etc.)

## Testing Checklist

For each migrated form:

- [ ] Form renders correctly
- [ ] Validation errors display on invalid input
- [ ] Successful submission works
- [ ] Redirects work (for create/edit forms)
- [ ] Toast notifications work (if applicable)
- [ ] Progressive enhancement works (disable JS)

## Notes

- Some forms may need the `AttributeBuilder` component updated - check its superforms usage
- The inventory items form has complex attribute validation - may need special handling
- Check if any forms use `SPA: true` mode - these need different handling (see Step 5)

## Next Step

Proceed to `05_migrate_complex_forms.md` to migrate the invite drawer and workshop form.
