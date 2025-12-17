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

Update `settings-sheet.svelte` using the new `Field` component:

```svelte
<script lang="ts">
  import { updateMemberSettings } from './data.remote';
  import * as Sheet from '$lib/components/ui/sheet/index.js';
  import * as Field from '$lib/components/ui/field';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import { Lock } from 'lucide-svelte';
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
      <Field.Field>
        {@const fieldProps = updateMemberSettings.fields.insuranceFormLink.as('url')}
        <Field.Label for={fieldProps.name}>HEMA Insurance Form Link</Field.Label>
        <Input
          {...fieldProps}
          id={fieldProps.name}
          placeholder="https://example.com/insurance-form"
        />
        {#each updateMemberSettings.fields.insuranceFormLink.issues() as issue}
          <Field.Error>{issue.message}</Field.Error>
        {/each}
      </Field.Field>
      
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

Update `create/+page.svelte` using the new `Field` component:

```svelte
<script lang="ts">
  import { createCategory } from '../data.remote';
  import * as Field from '$lib/components/ui/field';
  import { Input } from '$lib/components/ui/input';
  import { Textarea } from '$lib/components/ui/textarea';
  import { Button } from '$lib/components/ui/button';
  import * as Card from '$lib/components/ui/card';
</script>

<Card.Root>
  <Card.Header>
    <Card.Title>Create Category</Card.Title>
  </Card.Header>
  <Card.Content>
    <form {...createCategory} class="space-y-4">
      <Field.Group>
        <Field.Field>
          {@const fieldProps = createCategory.fields.name.as('text')}
          <Field.Label for={fieldProps.name}>Name</Field.Label>
          <Input {...fieldProps} id={fieldProps.name} placeholder="Category name" />
          {#each createCategory.fields.name.issues() as issue}
            <Field.Error>{issue.message}</Field.Error>
          {/each}
        </Field.Field>
        
        <Field.Field>
          {@const fieldProps = createCategory.fields.description.as('text')}
          <Field.Label for={fieldProps.name}>Description</Field.Label>
          <Textarea {...fieldProps} id={fieldProps.name} placeholder="Category description" />
          {#each createCategory.fields.description.issues() as issue}
            <Field.Error>{issue.message}</Field.Error>
          {/each}
        </Field.Field>
      </Field.Group>
      
      <div class="flex gap-2">
        <Button type="submit">Create</Button>
        <Button href="/dashboard/inventory/categories" variant="outline">Cancel</Button>
      </div>
    </form>
  </Card.Content>
</Card.Root>
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

The form uses `field.set()` to populate initial values. Using the new `Field` component:

```svelte
<script lang="ts">
  import { updateCategory, deleteCategory } from './data.remote';
  import * as Field from '$lib/components/ui/field';
  import { Input } from '$lib/components/ui/input';
  import { Textarea } from '$lib/components/ui/textarea';
  import { Button } from '$lib/components/ui/button';
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
  <Field.Group>
    <Field.Field>
      {@const fieldProps = updateCategory.fields.name.as('text')}
      <Field.Label for={fieldProps.name}>Name</Field.Label>
      <Input {...fieldProps} id={fieldProps.name} />
      {#each updateCategory.fields.name.issues() as issue}
        <Field.Error>{issue.message}</Field.Error>
      {/each}
    </Field.Field>
    
    <Field.Field>
      {@const fieldProps = updateCategory.fields.description.as('text')}
      <Field.Label for={fieldProps.name}>Description</Field.Label>
      <Textarea {...fieldProps} id={fieldProps.name} />
      {#each updateCategory.fields.description.issues() as issue}
        <Field.Error>{issue.message}</Field.Error>
      {/each}
    </Field.Field>
  </Field.Group>
  
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

Using the new `Field` component:

```svelte
<script lang="ts">
  import { createItem } from '../data.remote';
  import * as Field from '$lib/components/ui/field';
  import * as Select from '$lib/components/ui/select';
  import { Input } from '$lib/components/ui/input';
  
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
  <Field.Field>
    {@const fieldProps = createItem.fields.category_id.as('select')}
    <Field.Label for={fieldProps.name}>Category</Field.Label>
    <Select.Root 
      type="single"
      value={createItem.fields.category_id.value() as string}
      onValueChange={(v) => {
        createItem.fields.category_id.set(v);
        // Reset attributes when category changes
        createItem.fields.attributes.set({});
      }}
    >
      <Select.Trigger id={fieldProps.name}>
        {#if selectedCategory}
          {selectedCategory.name}
        {:else}
          Select a category
        {/if}
      </Select.Trigger>
      <Select.Content>
        {#each data.categories as category (category.id)}
          <Select.Item value={category.id} label={category.name} />
        {/each}
      </Select.Content>
    </Select.Root>
    <input type="hidden" name={fieldProps.name} value={createItem.fields.category_id.value() ?? ''} />
    {#each createItem.fields.category_id.issues() as issue}
      <Field.Error>{issue.message}</Field.Error>
    {/each}
  </Field.Field>
  
  <!-- Dynamic attributes -->
  {#if selectedCategory}
    <Field.Set>
      <Field.Legend>Attributes</Field.Legend>
      <Field.Group>
        {#each categoryAttributes as attr (attr.name)}
          {#if attr.type === 'text'}
            <Field.Field>
              {@const fieldProps = createItem.fields.attributes[attr.name].as('text')}
              <Field.Label for={fieldProps.name}>{attr.label}</Field.Label>
              <Input {...fieldProps} id={fieldProps.name} />
              {#each createItem.fields.attributes[attr.name].issues() as issue}
                <Field.Error>{issue.message}</Field.Error>
              {/each}
            </Field.Field>
          {/if}
        {/each}
      </Field.Group>
    </Field.Set>
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
