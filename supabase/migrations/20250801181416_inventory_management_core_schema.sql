-- Inventory Management System - Stage 1: Core Data Model & Database Schema
-- Enable pg-jsonschema extension for JSON Schema validation
CREATE EXTENSION IF NOT EXISTS pg_jsonschema WITH SCHEMA extensions;

-- Create enum for inventory history actions
CREATE TYPE inventory_action AS ENUM (
    'created',
    'moved', 
    'updated',
    'maintenance_out',
    'maintenance_in'
);

-- 1. CONTAINERS TABLE
-- Supports hierarchical nesting with self-referencing foreign key
CREATE TABLE containers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    description TEXT,
    parent_container_id UUID REFERENCES containers(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    created_by UUID REFERENCES auth.users(id) NOT NULL
);

-- 2. EQUIPMENT_CATEGORIES TABLE  
-- Flexible attribute system using JSONB with JSON Schema validation
CREATE TABLE equipment_categories (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL UNIQUE,
    description TEXT,
    available_attributes JSONB NOT NULL DEFAULT '{}',
    attribute_schema JSONB NOT NULL DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 3. INVENTORY_ITEMS TABLE
-- Equipment items with flexible attributes and container location
CREATE TABLE inventory_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    container_id UUID REFERENCES containers(id) NOT NULL,
    category_id UUID REFERENCES equipment_categories(id) NOT NULL,
    attributes JSONB NOT NULL DEFAULT '{}',
    quantity INTEGER NOT NULL DEFAULT 1 CHECK (quantity > 0),
    photo_url TEXT,
    out_for_maintenance BOOLEAN DEFAULT FALSE,
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    created_by UUID REFERENCES auth.users(id),
    updated_by UUID REFERENCES auth.users(id)
);

-- 4. INVENTORY_HISTORY TABLE
-- Complete audit trail for all inventory changes
CREATE TABLE inventory_history (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    item_id UUID REFERENCES inventory_items(id) ON DELETE CASCADE NOT NULL,
    action inventory_action NOT NULL,
    old_container_id UUID REFERENCES containers(id),
    new_container_id UUID REFERENCES containers(id),
    changed_by UUID REFERENCES auth.users(id) NOT NULL,
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- INDEXES for performance
CREATE INDEX idx_containers_parent ON containers(parent_container_id);
CREATE INDEX idx_containers_created_by ON containers(created_by);
CREATE INDEX idx_inventory_items_container ON inventory_items(container_id);
CREATE INDEX idx_inventory_items_category ON inventory_items(category_id);
CREATE INDEX idx_inventory_items_maintenance ON inventory_items(out_for_maintenance);
CREATE INDEX idx_inventory_history_item ON inventory_history(item_id);
CREATE INDEX idx_inventory_history_action ON inventory_history(action);
CREATE INDEX idx_inventory_history_changed_by ON inventory_history(changed_by);

-- FUNCTIONS AND TRIGGERS

-- Function to prevent circular references in container hierarchy
CREATE OR REPLACE FUNCTION check_container_hierarchy()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    current_id UUID;
    visited_ids UUID[];
BEGIN
    -- If no parent, no circular reference possible
    IF NEW.parent_container_id IS NULL THEN
        RETURN NEW;
    END IF;
    
    -- Start from the parent and traverse up the hierarchy
    current_id := NEW.parent_container_id;
    visited_ids := ARRAY[NEW.id];
    
    WHILE current_id IS NOT NULL LOOP
        -- If we encounter the current container ID, we have a circular reference
        IF current_id = NEW.id THEN
            RAISE EXCEPTION 'Circular reference detected in container hierarchy';
        END IF;
        
        -- If we've already visited this ID, we have a circular reference
        IF current_id = ANY(visited_ids) THEN
            RAISE EXCEPTION 'Circular reference detected in container hierarchy';
        END IF;
        
        -- Add current ID to visited list
        visited_ids := array_append(visited_ids, current_id);
        
        -- Move to the next parent
        SELECT parent_container_id INTO current_id 
        FROM public.containers 
        WHERE id = current_id;
    END LOOP;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger to check container hierarchy on insert/update
CREATE TRIGGER check_container_hierarchy_trigger
    BEFORE INSERT OR UPDATE ON containers
    FOR EACH ROW
    EXECUTE FUNCTION check_container_hierarchy();

-- Function to validate inventory item attributes against category schema
-- Uses pg-jsonschema extension for proper JSON Schema validation
CREATE OR REPLACE FUNCTION validate_item_attributes()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    category_schema JSONB;
BEGIN
    -- Get the attribute schema for this category
    SELECT attribute_schema INTO category_schema
    FROM public.equipment_categories
    WHERE id = NEW.category_id;
    
    -- If no schema defined, allow any attributes
    IF category_schema IS NULL OR category_schema = '{}' THEN
        RETURN NEW;
    END IF;
    
    -- Validate attributes against schema using pg-jsonschema
    IF NOT extensions.jsonb_matches_schema(category_schema::json, NEW.attributes) THEN
        RAISE EXCEPTION 'Item attributes do not match category schema. Schema: %, Attributes: %', 
            category_schema, NEW.attributes;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger to validate attributes on insert/update
CREATE TRIGGER validate_item_attributes_trigger
    BEFORE INSERT OR UPDATE ON inventory_items
    FOR EACH ROW
    EXECUTE FUNCTION validate_item_attributes();

-- Function to automatically create history records
CREATE OR REPLACE FUNCTION create_inventory_history()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    -- Handle INSERT (creation)
    IF TG_OP = 'INSERT' THEN
        INSERT INTO public.inventory_history (
            item_id, 
            action, 
            new_container_id, 
            changed_by,
            notes
        ) VALUES (
            NEW.id,
            'created',
            NEW.container_id,
            NEW.created_by,
            'Item created'
        );
        RETURN NEW;
    END IF;
    
    -- Handle UPDATE
    IF TG_OP = 'UPDATE' THEN
        -- Check if container changed (moved)
        IF OLD.container_id != NEW.container_id THEN
            INSERT INTO public.inventory_history (
                item_id,
                action,
                old_container_id,
                new_container_id,
                changed_by,
                notes
            ) VALUES (
                NEW.id,
                'moved',
                OLD.container_id,
                NEW.container_id,
                NEW.updated_by,
                'Item moved between containers'
            );
        END IF;
        
        -- Check if maintenance status changed
        IF OLD.out_for_maintenance != NEW.out_for_maintenance THEN
            INSERT INTO public.inventory_history (
                item_id,
                action,
                new_container_id,
                changed_by,
                notes
            ) VALUES (
                NEW.id,
                CASE WHEN NEW.out_for_maintenance THEN 'maintenance_out' ELSE 'maintenance_in' END,
                NEW.container_id,
                NEW.updated_by,
                CASE WHEN NEW.out_for_maintenance THEN 'Item sent for maintenance' ELSE 'Item returned from maintenance' END
            );
        END IF;
        
        -- Check if other attributes changed
        IF OLD.attributes != NEW.attributes OR OLD.quantity != NEW.quantity OR OLD.notes != NEW.notes THEN
            INSERT INTO public.inventory_history (
                item_id,
                action,
                new_container_id,
                changed_by,
                notes
            ) VALUES (
                NEW.id,
                'updated',
                NEW.container_id,
                NEW.updated_by,
                'Item details updated'
            );
        END IF;
        
        RETURN NEW;
    END IF;
    
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- Trigger to create history records
CREATE TRIGGER create_inventory_history_trigger
    AFTER INSERT OR UPDATE ON inventory_items
    FOR EACH ROW
    EXECUTE FUNCTION create_inventory_history();

-- Function to update updated_at timestamps
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Triggers for updated_at timestamps
CREATE TRIGGER update_containers_updated_at
    BEFORE UPDATE ON containers
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_equipment_categories_updated_at
    BEFORE UPDATE ON equipment_categories
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_inventory_items_updated_at
    BEFORE UPDATE ON inventory_items
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- ROW LEVEL SECURITY POLICIES

-- Enable RLS on all tables
ALTER TABLE containers ENABLE ROW LEVEL SECURITY;
ALTER TABLE equipment_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_history ENABLE ROW LEVEL SECURITY;

-- CONTAINERS policies
-- Quartermaster: Full access
CREATE POLICY "Quartermaster full access to containers" ON containers
    FOR ALL USING (
        has_any_role((SELECT auth.uid()), ARRAY['quartermaster', 'admin', 'president']::role_type[])
    );

-- Members: Read-only access
CREATE POLICY "Members read containers" ON containers
    FOR SELECT USING (
        has_any_role((SELECT auth.uid()), ARRAY['member', 'committee_coordinator', 'beginners_coordinator', 'quartermaster', 'admin', 'president']::role_type[])
    );

-- EQUIPMENT_CATEGORIES policies
-- Quartermaster: Full access
CREATE POLICY "Quartermaster full access to categories" ON equipment_categories
    FOR ALL USING (
        has_any_role((SELECT auth.uid()), ARRAY['quartermaster', 'admin', 'president']::role_type[])
    );

-- Members: Read-only access
CREATE POLICY "Members read categories" ON equipment_categories
    FOR SELECT USING (
        has_any_role((SELECT auth.uid()), ARRAY['member', 'committee_coordinator', 'beginners_coordinator', 'quartermaster', 'admin', 'president']::role_type[])
    );

-- INVENTORY_ITEMS policies
-- Quartermaster: Full access
CREATE POLICY "Quartermaster full access to items" ON inventory_items
    FOR ALL USING (
        has_any_role((SELECT auth.uid()), ARRAY['quartermaster', 'admin', 'president']::role_type[])
    );

-- Members: Read-only access, but cannot see items out for maintenance
CREATE POLICY "Members read items not in maintenance" ON inventory_items
    FOR SELECT USING (
        has_any_role((SELECT auth.uid()), ARRAY['member', 'committee_coordinator', 'beginners_coordinator', 'quartermaster', 'admin', 'president']::role_type[])
        AND out_for_maintenance = FALSE
    );

-- INVENTORY_HISTORY policies
-- Only quartermaster can access history
CREATE POLICY "Quartermaster access to history" ON inventory_history
    FOR ALL USING (
        has_any_role((SELECT auth.uid()), ARRAY['quartermaster', 'admin', 'president']::role_type[])
    );

-- SEED DEFAULT EQUIPMENT CATEGORIES

-- Insert default equipment categories with proper JSON schemas
INSERT INTO equipment_categories (name, description, available_attributes, attribute_schema) VALUES
(
    'Masks',
    'Protective masks for HEMA practice',
    '{
        "brand": {"type": "text", "required": true},
        "size": {"type": "select", "options": ["XS", "S", "M", "L", "XL"], "required": false},
        "colour": {"type": "text", "required": false}
    }',
    '{
        "type": "object",
        "properties": {
            "brand": {"type": "string"},
            "size": {"type": "string", "enum": ["XS", "S", "M", "L", "XL"]},
            "colour": {"type": "string"}
        },
        "required": ["brand"],
        "additionalProperties": false
    }'
),
(
    'Gorgets',
    'Throat protection for HEMA practice',
    '{
        "brand": {"type": "text", "required": true}
    }',
    '{
        "type": "object",
        "properties": {
            "brand": {"type": "string"}
        },
        "required": ["brand"],
        "additionalProperties": false
    }'
),
(
    'Gloves',
    'Hand protection for HEMA practice',
    '{
        "brand": {"type": "text", "required": true},
        "colour": {"type": "text", "required": false},
        "model": {"type": "text", "required": false}
    }',
    '{
        "type": "object",
        "properties": {
            "brand": {"type": "string"},
            "colour": {"type": "string"},
            "model": {"type": "string"}
        },
        "required": ["brand"],
        "additionalProperties": false
    }'
),
(
    'Plastrons',
    'Chest protection for HEMA practice',
    '{
        "size": {"type": "select", "options": ["XS", "S", "M", "L", "XL"], "required": false},
        "type": {"type": "select", "options": ["female", "male"], "required": false}
    }',
    '{
        "type": "object",
        "properties": {
            "size": {"type": "string", "enum": ["XS", "S", "M", "L", "XL"]},
            "type": {"type": "string", "enum": ["female", "male"]}
        },
        "additionalProperties": false
    }'
),
(
    'Jackets',
    'Protective jackets for HEMA practice',
    '{
        "brand": {"type": "text", "required": true},
        "colour": {"type": "text", "required": false},
        "size": {"type": "select", "options": ["XS", "S", "M", "L", "XL"], "required": false}
    }',
    '{
        "type": "object",
        "properties": {
            "brand": {"type": "string"},
            "colour": {"type": "string"},
            "size": {"type": "string", "enum": ["XS", "S", "M", "L", "XL"]}
        },
        "required": ["brand"],
        "additionalProperties": false
    }'
),
(
    'Arming Swords',
    'Single-handed swords for HEMA practice',
    '{
        "brand": {"type": "text", "required": true},
        "model": {"type": "text", "required": false}
    }',
    '{
        "type": "object",
        "properties": {
            "brand": {"type": "string"},
            "model": {"type": "string"}
        },
        "required": ["brand"],
        "additionalProperties": false
    }'
),
(
    'Longswords',
    'Two-handed swords for HEMA practice',
    '{
        "brand": {"type": "text", "required": true},
        "model": {"type": "text", "required": false}
    }',
    '{
        "type": "object",
        "properties": {
            "brand": {"type": "string"},
            "model": {"type": "string"}
        },
        "required": ["brand"],
        "additionalProperties": false
    }'
);

-- Create storage bucket for equipment photos (this will be handled separately in Supabase dashboard)
-- The bucket creation and policies will be configured via the Supabase dashboard or separate storage configuration