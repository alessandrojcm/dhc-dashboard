# Inventory Management System - Stage 1: Core Data Model & Database Schema

## Feature Overview

This is Stage 1 of implementing an inventory management system for the Dublin Hema Club (DHC) dashboard. The system allows the quartermaster role to manage equipment inventory and provides read-only access to members for locating gear.

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

## Stage 1 Objectives

Implement the core data model and database schema that will support the entire inventory management system.

### Database Schema Design

Create the following tables with proper relationships and RLS policies:

#### 1. containers
```sql
- id (UUID, primary key)
- name (text, required)
- description (text, optional)
- parent_container_id (UUID, foreign key to containers, nullable)
- created_at, updated_at (timestamps)
- created_by (UUID, foreign key to profiles)
```

**Key Features:**
- Supports hierarchical nesting (containers can contain other containers)
- Self-referencing foreign key for parent-child relationships
- Audit trail with created_by and timestamps

#### 2. equipment_categories
```sql
- id (UUID, primary key)
- name (text, required - e.g., "Masks", "Jackets", "Weapons")
- description (text, optional)
- available_attributes (jsonb - defines which attributes this category supports)
- attribute_schema (jsonb - JSON Schema for validating item attributes)
- created_at, updated_at (timestamps)
```

**Key Features:**
- Flexible attribute system using JSONB with JSON Schema validation
- Uses pg-jsonschema extension for robust attribute validation
- Examples of available_attributes:
  ```json
  {
    "brand": {"type": "text", "required": true},
    "size": {"type": "select", "options": ["XS", "S", "M", "L", "XL"], "required": false},
    "color": {"type": "text", "required": false}
  }
  ```
- Corresponding attribute_schema for validation:
  ```json
  {
    "type": "object",
    "properties": {
      "brand": {"type": "string"},
      "size": {"type": "string", "enum": ["XS", "S", "M", "L", "XL"]},
      "color": {"type": "string"}
    },
    "required": ["brand"]
  }
  ```

#### 3. inventory_items
```sql
- id (UUID, primary key)
- container_id (UUID, foreign key to containers, required)
- category_id (UUID, foreign key to equipment_categories, required)
- attributes (jsonb - stores actual attribute values, validated against category schema)
- quantity (integer, default 1)
- photo_url (text, optional - Supabase Storage URL)
- out_for_maintenance (boolean, default false)
- notes (text, optional)
- created_at, updated_at (timestamps)
- CONSTRAINT: attributes must match category's attribute_schema using json_matches_schema()
```

**Key Features:**
- Flexible attributes stored as JSONB with JSON Schema validation
- Quantity tracking (no serial numbers needed)
- Maintenance flag for tracking equipment status
- Photo support using Supabase Storage

#### 4. inventory_history
```sql
- id (UUID, primary key)
- item_id (UUID, foreign key to inventory_items, required)
- action (enum: 'created', 'moved', 'updated', 'maintenance_out', 'maintenance_in')
- old_container_id (UUID, nullable)
- new_container_id (UUID, nullable)
- changed_by (UUID, foreign key to profiles, required)
- notes (text, optional)
- created_at (timestamp)
```

**Key Features:**
- Complete audit trail for all inventory changes
- Tracks movements between containers
- Records maintenance status changes

### Row Level Security (RLS) Policies

Implement the following access patterns:

**Quartermaster Role:**
- Full CRUD access to all tables
- Can create, read, update, delete containers, categories, and items
- Can view all history records

**Members:**
- Read-only access to containers, categories, and inventory_items
- Cannot see items marked as `out_for_maintenance`
- Cannot access inventory_history table

**Public/Unauthenticated:**
- No access to any inventory tables

### Database Functions & Triggers

Create supporting database functions:

1. **Container hierarchy validation**: Prevent circular references in parent_container_id
2. **History trigger**: Automatically create history records on inventory_items changes
3. **Attribute validation**: Use JSON Schema validation to ensure item attributes match category schema
4. **JSON Schema setup**: Enable pg-jsonschema extension for robust attribute validation

### Migration Strategy

Create a new migration file that:
1. Enables pg-jsonschema extension for attribute validation
2. Creates all four tables with proper constraints
3. Sets up RLS policies
4. Creates necessary indexes for performance
5. Adds database functions and triggers
6. Seeds default equipment categories with proper schemas

## Implementation Tasks

1. **Extension Setup**
   - Enable pg-jsonschema extension in Supabase
   - Verify JSON Schema validation functions are available

2. **Create Migration File**
   - Design and implement the complete database schema
   - Add JSON Schema constraints for attribute validation
   - Add proper foreign key constraints and indexes
   - Implement RLS policies for role-based access

3. **Database Functions**
   - Container hierarchy validation function
   - JSON Schema attribute validation constraints
   - History tracking triggers
   - Helper functions for schema validation

4. **Storage Configuration**
   - Create Supabase Storage bucket for equipment photos
   - Set up proper access policies for photo uploads

5. **Seed Data**
   - Create default equipment categories with JSON Schema definitions
   - Validate schema definitions work correctly

6. **Type Generation**
   - Run `pnpm supabase:types` after migration
   - Verify generated types match schema design

7. **Testing**
   - Write unit tests for database with pgtap
   - Test JSON Schema validation with valid/invalid data
   - Test RLS policies with different user roles
   - Verify hierarchy constraints work correctly
   - Test photo upload functionality

## Implementation Decisions

Based on requirements analysis, the following decisions have been made:

1. **Default Categories**: Seed the following equipment categories in the migration:
   - **Masks**: brand (required), size (select: XS/S/M/L/XL), colour (text)
   - **Gorgets**: brand (required)
   - **Gloves**: brand (required), colour (text), model (text)
   - **Plastrons**: size (select: XS/S/M/L/XL), type (select: female/male)
   - **Jackets**: brand (required), colour (text), size (select: XS/S/M/L/XL)
   - **Arming Swords**: brand (required), model (text)
   - **Longswords**: brand (required), model (text)

2. **Attribute Types**: Support only text input and select dropdown options (no number, boolean, or date types)

3. **Container Limits**: No restrictions on nesting depth or maximum items per container

4. **Photo Storage**: Use Supabase Storage for equipment photos with proper bucket configuration

5. **Migration Strategy**: Starting fresh with no existing data to migrate

6. **Validation Rules**: 
   - Use JSON Schema validation for equipment attributes via pg-jsonschema extension
   - No validation required for container or category names
   - Attribute validation enforced at database level using JSON Schema constraints

### Default Category Schemas

Each equipment category will be seeded with both `available_attributes` (for UI form generation) and `attribute_schema` (for database validation):

**Example: Masks Category**
```json
{
  "available_attributes": {
    "brand": {"type": "text", "required": true},
    "size": {"type": "select", "options": ["XS", "S", "M", "L", "XL"], "required": false},
    "colour": {"type": "text", "required": false}
  },
  "attribute_schema": {
    "type": "object",
    "properties": {
      "brand": {"type": "string"},
      "size": {"type": "string", "enum": ["XS", "S", "M", "L", "XL"]},
      "colour": {"type": "string"}
    },
    "required": ["brand"],
    "additionalProperties": false
  }
}
```

**All Categories to Seed:**
- **Masks**: brand (required), size (XS/S/M/L/XL), colour
- **Gorgets**: brand (required)
- **Gloves**: brand (required), colour, model
- **Plastrons**: size (XS/S/M/L/XL), type (female/male)
- **Jackets**: brand (required), colour, size (XS/S/M/L/XL)
- **Arming Swords**: brand (required), model
- **Longswords**: brand (required), model

## Success Criteria

Stage 1 is complete when:
- [ ] pg-jsonschema extension is enabled and configured
- [ ] All database tables are created with proper relationships
- [ ] JSON Schema validation is working for equipment attributes
- [ ] RLS policies are implemented and tested
- [ ] Database functions and triggers are working
- [ ] Default equipment categories are seeded with proper schemas
- [ ] TypeScript types are generated and accurate
- [ ] Basic CRUD operations are functional
- [ ] Unit tests pass for all database operations
- [ ] Schema supports the hierarchical container structure
- [ ] Supabase Storage bucket is configured for equipment photos

## Next Stages

After Stage 1 completion:
- **Stage 2**: Quartermaster Management Interface - Build the admin UI for managing containers, categories, and items
- **Stage 3**: Advanced Organization & Search - Implement tree view, advanced search, and bulk operations
- **Stage 4**: Member Read-Only Interface - Create public inventory browser for members
