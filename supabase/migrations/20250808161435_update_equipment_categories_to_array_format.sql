-- Update equipment_categories to use array format for available_attributes
-- This migration converts the existing object format to array format as specified in the updated requirements

-- First, create the functions for schema generation and triggers
CREATE OR REPLACE FUNCTION generate_attribute_schema(attributes_array jsonb)
RETURNS jsonb AS $$
DECLARE
  schema jsonb := '{"type": "object", "properties": {}, "additionalProperties": false}'::jsonb;
  required_fields text[] := '{}';
  attr jsonb;
  attr_name text;
  attr_type text;
  property_schema jsonb;
BEGIN
  -- Handle null or empty input
  IF attributes_array IS NULL OR jsonb_array_length(attributes_array) = 0 THEN
    RETURN schema;
  END IF;

  FOR attr IN SELECT jsonb_array_elements(attributes_array)
  LOOP
    -- Extract attribute name and type safely
    attr_name := attr->>'name';
    attr_type := attr->>'type';
    
    -- Skip if name is null or empty
    IF attr_name IS NULL OR attr_name = '' THEN
      CONTINUE;
    END IF;
    
    -- Build property schema based on type
    IF attr_type = 'select' AND attr->'options' IS NOT NULL THEN
      property_schema := jsonb_build_object('type', 'string', 'enum', attr->'options');
    ELSE
      property_schema := jsonb_build_object('type', 'string');
    END IF;
    
    -- Add property to schema using concat instead of jsonb_set for better null handling
    schema := schema || jsonb_build_object('properties', 
      COALESCE(schema->'properties', '{}'::jsonb) || jsonb_build_object(attr_name, property_schema)
    );
    
    -- Add to required array if needed
    IF COALESCE((attr->>'required')::boolean, false) THEN
      required_fields := array_append(required_fields, attr_name);
    END IF;
  END LOOP;
  
  -- Set required fields if any exist
  IF array_length(required_fields, 1) > 0 THEN
    schema := schema || jsonb_build_object('required', to_jsonb(required_fields));
  END IF;
  
  RETURN schema;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION update_category_schema()
RETURNS TRIGGER AS $$
BEGIN
  NEW.attribute_schema := generate_attribute_schema(NEW.available_attributes);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Drop existing trigger if it exists
DROP TRIGGER IF EXISTS category_schema_trigger ON equipment_categories;

-- Create trigger to auto-update attribute_schema when available_attributes changes
CREATE TRIGGER category_schema_trigger
  BEFORE INSERT OR UPDATE ON equipment_categories
  FOR EACH ROW
  EXECUTE FUNCTION update_category_schema();

-- Update existing equipment categories to use array format
-- Clear existing data and insert with new array format
DELETE FROM equipment_categories;

-- Insert categories with array format for available_attributes
INSERT INTO equipment_categories (name, description, available_attributes) VALUES
(
    'Masks',
    'Protective masks for HEMA practice',
    '[
        {
            "name": "brand",
            "type": "text",
            "required": true,
            "label": "Brand"
        },
        {
            "name": "size",
            "type": "select",
            "options": ["XS", "S", "M", "L", "XL"],
            "required": false,
            "label": "Size"
        },
        {
            "name": "colour",
            "type": "text",
            "required": false,
            "label": "Colour"
        }
    ]'::jsonb
),
(
    'Gorgets',
    'Throat protection for HEMA practice',
    '[
        {
            "name": "brand",
            "type": "text",
            "required": true,
            "label": "Brand"
        }
    ]'::jsonb
),
(
    'Gloves',
    'Hand protection for HEMA practice',
    '[
        {
            "name": "brand",
            "type": "text",
            "required": true,
            "label": "Brand"
        },
        {
            "name": "colour",
            "type": "text",
            "required": false,
            "label": "Colour"
        },
        {
            "name": "model",
            "type": "text",
            "required": false,
            "label": "Model"
        }
    ]'::jsonb
),
(
    'Plastrons',
    'Chest protection for HEMA practice',
    '[
        {
            "name": "size",
            "type": "select",
            "options": ["XS", "S", "M", "L", "XL"],
            "required": false,
            "label": "Size"
        },
        {
            "name": "type",
            "type": "select",
            "options": ["female", "male"],
            "required": false,
            "label": "Type"
        }
    ]'::jsonb
),
(
    'Jackets',
    'Protective jackets for HEMA practice',
    '[
        {
            "name": "brand",
            "type": "text",
            "required": true,
            "label": "Brand"
        },
        {
            "name": "colour",
            "type": "text",
            "required": false,
            "label": "Colour"
        },
        {
            "name": "size",
            "type": "select",
            "options": ["XS", "S", "M", "L", "XL"],
            "required": false,
            "label": "Size"
        }
    ]'::jsonb
),
(
    'Arming Swords',
    'Single-handed swords for HEMA practice',
    '[
        {
            "name": "brand",
            "type": "text",
            "required": true,
            "label": "Brand"
        },
        {
            "name": "model",
            "type": "text",
            "required": false,
            "label": "Model"
        }
    ]'::jsonb
),
(
    'Longswords',
    'Two-handed swords for HEMA practice',
    '[
        {
            "name": "brand",
            "type": "text",
            "required": true,
            "label": "Brand"
        },
        {
            "name": "model",
            "type": "text",
            "required": false,
            "label": "Model"
        }
    ]'::jsonb
);