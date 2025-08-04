# Inventory Management System - Stage 2: Quartermaster Management Interface

NOTES:
This is implemented, we just need to fix some server side error loaders
and do a full e2e test. Remove the key property from the category creator

## Feature Overview

This is Stage 2 of implementing an inventory management system for the Dublin Hema Club (DHC) dashboard. This stage builds upon the core data model from Stage 1 to create the administrative interface for quartermasters to manage inventory.

### Complete Feature Requirements

The inventory management system needs to support:

**For Admin/Quartermaster:**
- Category creation with hierarchical organization (containers → equipment types)
- Equipment categories with flexible attributes (brand, size, color, type, etc.)
- Gear creation and management with comprehensive search capabilities
- Tree view or e-commerce style interface for inventory management

**For Members:**
- Read-only view to browse inventory and locate gear
- Search functionality to find where specific equipment is stored

### System Architecture

The system uses a hierarchical structure:
```
Container: "Main Storage Room"
├── Container: "Black Duffel Bag #1"
│   ├── Equipment: "Mask - Absolute Force - Medium - Black"
│   └── Equipment: "Jacket - PBT - Large - White"
└── Container: "Rolling Cage"
    └── Container: "Weapon Rack"
        └── Equipment: "Synthetic Longsword - Red Dragon - Standard"
```

## Stage 2 Objectives

Build the complete administrative interface for quartermasters to manage the inventory system, including container management, category management, and item management with dynamic forms.

### Prerequisites

- Stage 1 must be completed (database schema, RLS policies, basic CRUD operations)
- Quartermaster role exists and is properly configured
- Database types are generated and up-to-date

## User Interface Structure

### Route Organization
```
/dashboard/inventory/
├── +page.svelte                    # Dashboard overview with stats
├── containers/                     # Container management
│   ├── +page.svelte               # List all containers (tree view)
│   ├── +page.server.ts            # Load containers with hierarchy
│   ├── create/
│   │   ├── +page.svelte           # Create new container form
│   │   └── +page.server.ts        # Handle container creation
│   └── [id]/
│       ├── +page.svelte           # View/edit container details
│       ├── +page.server.ts        # Load container with contents
│       └── edit/
│           ├── +page.svelte       # Edit container form
│           └── +page.server.ts    # Handle container updates
├── categories/                     # Equipment category management
│   ├── +page.svelte               # List all categories
│   ├── +page.server.ts            # Load categories
│   ├── create/
│   │   ├── +page.svelte           # Create category with attributes
│   │   └── +page.server.ts        # Handle category creation
│   └── [id]/
│       └── edit/
│           ├── +page.svelte       # Edit category and attributes
│           └── +page.server.ts    # Handle category updates
├── items/                          # Individual item management
│   ├── +page.svelte               # List/search all items
│   ├── +page.server.ts            # Load items with filtering
│   ├── create/
│   │   ├── +page.svelte           # Create new item (dynamic form)
│   │   └── +page.server.ts        # Handle item creation
│   └── [id]/
│       ├── +page.svelte           # View item details + history
│       ├── +page.server.ts        # Load item with history
│       └── edit/
│           ├── +page.svelte       # Edit item form
│           └── +page.server.ts    # Handle item updates
└── +layout.svelte                 # Inventory section layout with navigation
```

## Key Components to Build

### 1. Container Management Components

**ContainerTreeView.svelte**
- Hierarchical display of containers
- Expandable/collapsible nodes
- Show item counts per container
- Drag-and-drop support for moving items (future enhancement)
- Actions: Create child container, edit, delete

**ContainerForm.svelte**
- Dynamic form for creating/editing containers
- Parent container selection (dropdown with hierarchy)
- Name and description fields
- Validation for circular references

### 2. Category Management Components

**CategoryList.svelte**
- Table/grid view of all equipment categories
- Show attribute count and usage statistics
- Actions: Create, edit, delete categories

**CategoryForm.svelte**
- Form for creating/editing categories
- Dynamic attribute builder interface
- Support for different attribute types:
  - Text input
  - Select dropdown (with options)
  - Number input
  - Boolean checkbox
- Attribute configuration (required/optional, default values)

**AttributeBuilder.svelte**
- Sub-component for building category attributes
- Add/remove attribute fields
- Configure attribute properties (type, options, required)
- Preview of how attributes will appear in item forms

### 3. Item Management Components

**ItemList.svelte**
- Comprehensive item listing with search and filters
- Filter by: container, category, attributes, maintenance status
- Sortable columns
- Bulk selection for future bulk operations
- Pagination for large inventories

**DynamicItemForm.svelte**
- Form that adapts based on selected category
- Renders appropriate input types based on category attributes
- Container selection with hierarchy display
- Photo upload functionality
- Quantity and maintenance status fields

**ItemDetails.svelte**
- Complete item information display
- Photo gallery if multiple photos
- Current location (container hierarchy path)
- Maintenance status and notes
- Action buttons: Edit, Move, Toggle maintenance

**ItemHistory.svelte**
- Timeline view of item changes
- Show: creation, moves, updates, maintenance changes
- Display user who made changes and timestamps
- Filter by action type

### 4. Shared Components

**ContainerSelector.svelte**
- Reusable component for selecting containers
- Hierarchical dropdown or tree picker
- Used in item forms and container parent selection

**PhotoUpload.svelte**
- Image upload with preview
- Integration with Supabase storage
- Image compression and validation
- Multiple photo support

**SearchFilters.svelte**
- Advanced filtering interface
- Dynamic filters based on available categories and attributes
- Save/load filter presets

## Data Loading and Form Handling

### Page Loaders (using Supabase client)

**Container Data Loading:**
```typescript
// containers/+page.server.ts - Load container hierarchy
export const load = async ({ locals: { supabase } }) => {
  const { data: containers } = await supabase
    .from('containers')
    .select('*, parent_container:parent_container_id(*)')
    .order('name');
  return { containers };
};

// containers/[id]/+page.server.ts - Load container with contents
export const load = async ({ params, locals: { supabase } }) => {
  const [containerResult, itemsResult] = await Promise.all([
    supabase.from('containers').select('*').eq('id', params.id).single(),
    supabase.from('inventory_items').select('*, category:equipment_categories(*)').eq('container_id', params.id)
  ]);
  return { container: containerResult.data, items: itemsResult.data };
};
```

**Category Data Loading:**
```typescript
// categories/+page.server.ts - Load all categories
export const load = async ({ locals: { supabase } }) => {
  const { data: categories } = await supabase
    .from('equipment_categories')
    .select('*')
    .order('name');
  return { categories };
};
```

**Item Data Loading:**
```typescript
// items/+page.server.ts - Load items with filtering
export const load = async ({ url, locals: { supabase } }) => {
  let query = supabase
    .from('inventory_items')
    .select('*, container:containers(*), category:equipment_categories(*)');
  
  // Apply filters from URL params
  const categoryFilter = url.searchParams.get('category');
  const containerFilter = url.searchParams.get('container');
  const search = url.searchParams.get('search');
  
  if (categoryFilter) query = query.eq('category_id', categoryFilter);
  if (containerFilter) query = query.eq('container_id', containerFilter);
  if (search) query = query.textSearch('attributes', search);
  
  const { data: items } = await query.order('created_at', { ascending: false });
  return { items };
};
```

### Client-Side Data Fetching (for real-time updates)

For components that need real-time data updates, use Supabase client directly:

```typescript
// In Svelte components - use Supabase client for reactive queries
<script>
  import { createQuery } from '@tanstack/svelte-query';
  
  export let data; // From page loader
  
  // Use TanStack Query for real-time updates when needed
  const containersQuery = createQuery(() => ({
    queryKey: ['containers'],
    queryFn: async () => {
      const { data } = await supabase
        .from('containers')
        .select('*, parent_container:parent_container_id(*)')
        .order('name');
      return data;
    },
    initialData: data.containers, // Use server-loaded data as initial
    refetchInterval: 30000 // Optional: refresh every 30 seconds
  }));
</script>

{#each $containersQuery.data as container}
  <div>{container.name}</div>
{/each}
```

### Form Actions (using Kysely with RLS)

**Container Actions:**
```typescript
// containers/create/+page.server.ts
import { superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import { fail, redirect } from '@sveltejs/kit';
import { containerSchema } from '$lib/schemas/inventory';

export const load = async ({ locals: { supabase } }) => {
  // Load parent containers for selection
  const { data: containers } = await supabase
    .from('containers')
    .select('id, name')
    .order('name');
  
  return {
    form: await superValidate(valibot(containerSchema)),
    containers
  };
};

export const actions = {
  default: async ({ request, locals: { executeWithRLS } }) => {
    const form = await superValidate(request, valibot(containerSchema));
    if (!form.valid) return fail(400, { form });
    
    const result = await executeWithRLS(
      db.insertInto('containers')
        .values({
          id: crypto.randomUUID(),
          name: form.data.name,
          description: form.data.description,
          parent_container_id: form.data.parent_container_id,
          created_at: new Date().toISOString()
        })
        .returningAll()
    );
    
    redirect(303, `/dashboard/inventory/containers/${result[0].id}`);
  }
};

// containers/[id]/edit/+page.server.ts
export const load = async ({ params, locals: { supabase } }) => {
  const [containerResult, containersResult] = await Promise.all([
    supabase.from('containers').select('*').eq('id', params.id).single(),
    supabase.from('containers').select('id, name').order('name')
  ]);
  
  return {
    form: await superValidate(containerResult.data, valibot(containerSchema)),
    containers: containersResult.data
  };
};

export const actions = {
  update: async ({ params, request, locals: { executeWithRLS } }) => {
    const form = await superValidate(request, valibot(containerSchema));
    if (!form.valid) return fail(400, { form });
    
    const result = await executeWithRLS(
      db.updateTable('containers')
        .set({
          name: form.data.name,
          description: form.data.description,
          parent_container_id: form.data.parent_container_id,
          updated_at: new Date().toISOString()
        })
        .where('id', '=', params.id)
        .returningAll()
    );
    
    return { form };
  },
  
  delete: async ({ params, locals: { executeWithRLS } }) => {
    await executeWithRLS(
      db.deleteFrom('containers').where('id', '=', params.id)
    );
    redirect(303, '/dashboard/inventory/containers');
  }
};
```

**Category Actions:**
```typescript
// categories/create/+page.server.ts
export const actions = {
  default: async ({ request, locals: { executeWithRLS } }) => {
    const form = await superValidate(request, categorySchema);
    if (!form.valid) return fail(400, { form });
    
    const result = await executeWithRLS(
      db.insertInto('equipment_categories')
        .values({
          id: crypto.randomUUID(),
          name: form.data.name,
          description: form.data.description,
          available_attributes: form.data.available_attributes,
          created_at: new Date().toISOString()
        })
        .returningAll()
    );
    
    return { form, category: result[0] };
  }
};
```

**Item Actions:**
```typescript
// items/create/+page.server.ts
export const actions = {
  default: async ({ request, locals: { executeWithRLS } }) => {
    const form = await superValidate(request, itemSchema);
    if (!form.valid) return fail(400, { form });
    
    const result = await executeWithRLS(
      db.insertInto('inventory_items')
        .values({
          id: crypto.randomUUID(),
          container_id: form.data.container_id,
          category_id: form.data.category_id,
          attributes: form.data.attributes,
          quantity: form.data.quantity,
          notes: form.data.notes,
          out_for_maintenance: form.data.out_for_maintenance,
          created_at: new Date().toISOString()
        })
        .returningAll()
    );
    
    return { form, item: result[0] };
  }
};

// items/[id]/+page.server.ts
export const actions = {
  update: async ({ params, request, locals: { executeWithRLS } }) => {
    const form = await superValidate(request, itemSchema);
    if (!form.valid) return fail(400, { form });
    
    const result = await executeWithRLS(
      db.updateTable('inventory_items')
        .set({
          container_id: form.data.container_id,
          category_id: form.data.category_id,
          attributes: form.data.attributes,
          quantity: form.data.quantity,
          notes: form.data.notes,
          out_for_maintenance: form.data.out_for_maintenance,
          updated_at: new Date().toISOString()
        })
        .where('id', '=', params.id)
        .returningAll()
    );
    
    return { form, item: result[0] };
  },
  
  move: async ({ params, request, locals: { executeWithRLS } }) => {
    const formData = await request.formData();
    const newContainerId = formData.get('container_id') as string;
    
    const result = await executeWithRLS(
      db.updateTable('inventory_items')
        .set({
          container_id: newContainerId,
          updated_at: new Date().toISOString()
        })
        .where('id', '=', params.id)
        .returningAll()
    );
    
    return { item: result[0] };
  },
  
  toggleMaintenance: async ({ params, locals: { executeWithRLS } }) => {
    const result = await executeWithRLS(
      db.updateTable('inventory_items')
        .set({
          out_for_maintenance: db.selectFrom('inventory_items')
            .select(sql`NOT out_for_maintenance`.as('toggle'))
            .where('id', '=', params.id),
          updated_at: new Date().toISOString()
        })
        .where('id', '=', params.id)
        .returningAll()
    );
    
    return { item: result[0] };
  }
};
```

## Validation Schemas

Create Valibot schemas for:

### Container Schema
```typescript
const containerSchema = object({
  name: pipe(string(), minLength(1), maxLength(100)),
  description: optional(pipe(string(), maxLength(500))),
  parent_container_id: optional(string()) // UUID validation
});
```

### Category Schema
```typescript
const categorySchema = object({
  name: pipe(string(), minLength(1), maxLength(50)),
  description: optional(pipe(string(), maxLength(500))),
  available_attributes: object({}) // Dynamic validation based on attribute types
});
```

### Item Schema
```typescript
const itemSchema = object({
  container_id: string(), // UUID validation
  category_id: string(), // UUID validation
  attributes: object({}), // Dynamic validation based on category
  quantity: pipe(number(), minValue(1)),
  notes: optional(pipe(string(), maxLength(1000))),
  out_for_maintenance: boolean()
});
```

## State Management

### SuperForms Integration (Svelte 5 Syntax)

**Form Setup in Components:**
```typescript
// containers/create/+page.svelte
<script lang="ts">
  import { superForm } from 'sveltekit-superforms';
  import { valibot } from 'sveltekit-superforms/adapters';
  import { containerSchema } from '$lib/schemas/inventory';
  
  let { data } = $props();
  
  const { form, errors, enhance, submitting } = superForm(data.form, {
    validators: valibot(containerSchema),
    resetForm: true
  });
</script>

<form method="POST" use:enhance>
  <input bind:value={$form.name} name="name" />
  {#if $errors.name}<span class="error">{$errors.name}</span>{/if}
  
  <textarea bind:value={$form.description} name="description"></textarea>
  {#if $errors.description}<span class="error">{$errors.description}</span>{/if}
  
  <select bind:value={$form.parent_container_id} name="parent_container_id">
    <option value="">No parent container</option>
    {#each data.containers as container}
      <option value={container.id}>{container.name}</option>
    {/each}
  </select>
  
  <button type="submit" disabled={$submitting}>
    {$submitting ? 'Creating...' : 'Create Container'}
  </button>
</form>
```

**Dynamic Item Forms:**
```typescript
// items/create/+page.svelte
<script lang="ts">
  import { superForm } from 'sveltekit-superforms';
  import { valibot } from 'sveltekit-superforms/adapters';
  import { itemSchema } from '$lib/schemas/inventory';
  import DynamicAttributeFields from '$lib/components/inventory/DynamicAttributeFields.svelte';
  
  let { data } = $props();
  
  const { form, errors, enhance, submitting } = superForm(data.form, {
    validators: valibot(itemSchema)
  });
  
  // Reactive category selection for dynamic attributes using $derived
  let selectedCategory = $derived(
    data.categories.find(c => c.id === $form.category_id)
  );
</script>

<form method="POST" use:enhance>
  <select bind:value={$form.category_id} name="category_id">
    <option value="">Select a category</option>
    {#each data.categories as category}
      <option value={category.id}>{category.name}</option>
    {/each}
  </select>
  
  <select bind:value={$form.container_id} name="container_id">
    <option value="">Select a container</option>
    {#each data.containers as container}
      <option value={container.id}>{container.name}</option>
    {/each}
  </select>
  
  {#if selectedCategory}
    <DynamicAttributeFields 
      category={selectedCategory} 
      bind:attributes={$form.attributes} 
      errors={$errors.attributes} 
    />
  {/if}
  
  <input type="number" bind:value={$form.quantity} name="quantity" min="1" />
  
  <button type="submit" disabled={$submitting}>
    {$submitting ? 'Creating...' : 'Create Item'}
  </button>
</form>
```

### Client-Side Data Fetching (when needed)

For real-time updates or complex interactions, use TanStack Query:

```typescript
// For dashboard stats that update frequently
const statsQuery = createQuery(() => ({
  queryKey: ['inventory-stats'],
  queryFn: async () => {
    const response = await fetch('/api/inventory/stats');
    return response.json();
  },
  refetchInterval: 30000 // Refresh every 30 seconds
}));

// For search functionality with debouncing
const searchQuery = createQuery(() => ({
  queryKey: ['inventory-search', searchTerm],
  queryFn: async () => {
    if (!searchTerm) return [];
    const response = await fetch(`/api/inventory/search?q=${encodeURIComponent(searchTerm)}`);
    return response.json();
  },
  enabled: searchTerm.length > 2
}));
```

## User Experience Features

### Dashboard Overview
- Total containers, categories, and items count
- Items out for maintenance count
- Recent activity feed
- Quick actions: Add container, Add category, Add item

### Navigation
- Breadcrumb navigation showing current location
- Quick search bar in header
- Sidebar navigation between containers/categories/items

### Form Enhancements
- Auto-save drafts for long forms
- Form validation with helpful error messages
- Success notifications after actions
- Confirmation dialogs for destructive actions

### Search and Filtering
- Global search across all items
- Advanced filters with multiple criteria
- Search suggestions and autocomplete
- Save frequently used filter combinations

## Implementation Tasks

1. **Route Structure Setup**
   - Create all route files with proper server-side loading
   - Implement role-based access control for quartermaster routes
   - Set up layout with navigation

2. **Core Components**
   - Build container tree view with hierarchy display
   - Create dynamic category form with attribute builder
   - Implement dynamic item form that adapts to categories
   - Build comprehensive item listing with search/filters

3. **Form Actions and Data Loading**
   - Implement all CRUD operations using SvelteKit form actions
   - Set up page loaders for data fetching with Supabase client
   - Add search and filtering capabilities through URL parameters
   - Integrate photo upload with Supabase storage (separate API endpoint if needed)

4. **Form Handling and State Management**
   - Set up SuperForms for all form interactions with proper validation
   - Use page loaders for initial data loading and navigation
   - Add TanStack Query only for real-time features (search, stats)
   - Implement proper error handling and success feedback

5. **Testing**
   - Write E2E tests for all major workflows
   - Test form validation and error handling
   - Verify role-based access control

## Success Criteria

Stage 2 is complete when:
- [ ] Quartermasters can create and manage container hierarchies
- [ ] Category management with flexible attributes is functional
- [ ] Dynamic item forms work correctly based on category selection
- [ ] Search and filtering across items works effectively
- [ ] Photo upload and display is working
- [ ] Item history tracking is visible and accurate
- [ ] All forms have proper validation and error handling
- [ ] Role-based access control is enforced
- [ ] E2E tests cover all major workflows
- [ ] UI is responsive and user-friendly

## Next Stages

After Stage 2 completion:
- **Stage 3**: Advanced Organization & Search - Enhanced tree view, bulk operations, advanced search features
- **Stage 4**: Member Read-Only Interface - Public inventory browser for members
