# Inventory Management System - Stage 2: Quartermaster Management Interface

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

## API Endpoints to Implement

### Container Endpoints
```typescript
// GET /api/inventory/containers - List all containers with hierarchy
// POST /api/inventory/containers - Create new container
// GET /api/inventory/containers/[id] - Get container with contents
// PUT /api/inventory/containers/[id] - Update container
// DELETE /api/inventory/containers/[id] - Delete container (if empty)
```

### Category Endpoints
```typescript
// GET /api/inventory/categories - List all categories
// POST /api/inventory/categories - Create new category
// GET /api/inventory/categories/[id] - Get category details
// PUT /api/inventory/categories/[id] - Update category and attributes
// DELETE /api/inventory/categories/[id] - Delete category (if unused)
```

### Item Endpoints
```typescript
// GET /api/inventory/items - List items with filtering/search
// POST /api/inventory/items - Create new item
// GET /api/inventory/items/[id] - Get item with history
// PUT /api/inventory/items/[id] - Update item
// DELETE /api/inventory/items/[id] - Delete item
// POST /api/inventory/items/[id]/move - Move item to different container
// PUT /api/inventory/items/[id]/maintenance - Toggle maintenance status
```

### Utility Endpoints
```typescript
// GET /api/inventory/search - Advanced search across items
// GET /api/inventory/stats - Dashboard statistics
// POST /api/inventory/photos - Upload item photos
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

### TanStack Query Integration

**Queries:**
- `useContainers()` - Fetch container hierarchy
- `useCategories()` - Fetch all categories
- `useItems(filters)` - Fetch items with filtering
- `useItemHistory(itemId)` - Fetch item history
- `useInventoryStats()` - Dashboard statistics

**Mutations:**
- `useCreateContainer()` - Create new container
- `useUpdateContainer()` - Update container
- `useDeleteContainer()` - Delete container
- `useCreateCategory()` - Create new category
- `useUpdateCategory()` - Update category
- `useCreateItem()` - Create new item
- `useUpdateItem()` - Update item
- `useMoveItem()` - Move item between containers
- `useToggleMaintenance()` - Toggle maintenance status

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

3. **API Endpoints**
   - Implement all CRUD endpoints with proper validation
   - Add search and filtering capabilities
   - Integrate photo upload with Supabase storage

4. **State Management**
   - Set up TanStack Query hooks for all data operations
   - Implement optimistic updates for better UX
   - Add error handling and retry logic

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