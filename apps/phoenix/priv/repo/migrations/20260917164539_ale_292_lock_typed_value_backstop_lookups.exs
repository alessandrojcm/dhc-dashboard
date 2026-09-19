defmodule Dhc.Repo.Migrations.Ale292LockTypedValueBackstopLookups do
  @moduledoc """
  Share-lock definition and option rows that the typed-value trigger
  validates against, so a concurrent type change or option move cannot
  commit an invalid pairing.
  """

  use Ecto.Migration

  def up do
    execute """
    CREATE OR REPLACE FUNCTION inventory_item_property_values_reject_type_mismatch() RETURNS trigger AS $$
    DECLARE
      definition_type text;
      option_definition uuid;
    BEGIN
      SELECT value_type INTO definition_type
        FROM inventory_property_definitions
       WHERE id = NEW.property_definition_id
       FOR SHARE;

      IF definition_type IS NULL THEN
        RAISE EXCEPTION 'property definition not found'
          USING ERRCODE = '23503';
      END IF;

      -- Leave empty / multi-column rows to the exactly-one check.
      IF (CASE WHEN NEW.text_value IS NOT NULL THEN 1 ELSE 0 END) +
         (CASE WHEN NEW.decimal_value IS NOT NULL THEN 1 ELSE 0 END) +
         (CASE WHEN NEW.boolean_value IS NOT NULL THEN 1 ELSE 0 END) +
         (CASE WHEN NEW.option_id IS NOT NULL THEN 1 ELSE 0 END) <> 1 THEN
        RETURN NEW;
      END IF;

      IF definition_type = 'text' AND NEW.text_value IS NULL THEN
        RAISE EXCEPTION 'text definition requires text_value'
          USING ERRCODE = '23514', CONSTRAINT = 'inventory_item_property_values_value_type_match';
      END IF;

      IF definition_type = 'decimal' AND NEW.decimal_value IS NULL THEN
        RAISE EXCEPTION 'decimal definition requires decimal_value'
          USING ERRCODE = '23514', CONSTRAINT = 'inventory_item_property_values_value_type_match';
      END IF;

      IF definition_type = 'boolean' AND NEW.boolean_value IS NULL THEN
        RAISE EXCEPTION 'boolean definition requires boolean_value'
          USING ERRCODE = '23514', CONSTRAINT = 'inventory_item_property_values_value_type_match';
      END IF;

      IF definition_type = 'single_select' AND NEW.option_id IS NULL THEN
        RAISE EXCEPTION 'single_select definition requires option_id'
          USING ERRCODE = '23514', CONSTRAINT = 'inventory_item_property_values_value_type_match';
      END IF;

      IF NEW.option_id IS NOT NULL THEN
        SELECT property_definition_id INTO option_definition
          FROM inventory_property_options
         WHERE id = NEW.option_id
         FOR SHARE;

        IF option_definition IS DISTINCT FROM NEW.property_definition_id THEN
          RAISE EXCEPTION 'option does not belong to the property definition'
            USING ERRCODE = '23514', CONSTRAINT = 'inventory_item_property_values_option_membership';
        END IF;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """
  end

  def down do
    execute """
    CREATE OR REPLACE FUNCTION inventory_item_property_values_reject_type_mismatch() RETURNS trigger AS $$
    DECLARE
      definition_type text;
      option_definition uuid;
    BEGIN
      SELECT value_type INTO definition_type
        FROM inventory_property_definitions
       WHERE id = NEW.property_definition_id;

      IF definition_type IS NULL THEN
        RAISE EXCEPTION 'property definition not found'
          USING ERRCODE = '23503';
      END IF;

      -- Leave empty / multi-column rows to the exactly-one check.
      IF (CASE WHEN NEW.text_value IS NOT NULL THEN 1 ELSE 0 END) +
         (CASE WHEN NEW.decimal_value IS NOT NULL THEN 1 ELSE 0 END) +
         (CASE WHEN NEW.boolean_value IS NOT NULL THEN 1 ELSE 0 END) +
         (CASE WHEN NEW.option_id IS NOT NULL THEN 1 ELSE 0 END) <> 1 THEN
        RETURN NEW;
      END IF;

      IF definition_type = 'text' AND NEW.text_value IS NULL THEN
        RAISE EXCEPTION 'text definition requires text_value'
          USING ERRCODE = '23514', CONSTRAINT = 'inventory_item_property_values_value_type_match';
      END IF;

      IF definition_type = 'decimal' AND NEW.decimal_value IS NULL THEN
        RAISE EXCEPTION 'decimal definition requires decimal_value'
          USING ERRCODE = '23514', CONSTRAINT = 'inventory_item_property_values_value_type_match';
      END IF;

      IF definition_type = 'boolean' AND NEW.boolean_value IS NULL THEN
        RAISE EXCEPTION 'boolean definition requires boolean_value'
          USING ERRCODE = '23514', CONSTRAINT = 'inventory_item_property_values_value_type_match';
      END IF;

      IF definition_type = 'single_select' AND NEW.option_id IS NULL THEN
        RAISE EXCEPTION 'single_select definition requires option_id'
          USING ERRCODE = '23514', CONSTRAINT = 'inventory_item_property_values_value_type_match';
      END IF;

      IF NEW.option_id IS NOT NULL THEN
        SELECT property_definition_id INTO option_definition
          FROM inventory_property_options
         WHERE id = NEW.option_id;

        IF option_definition IS DISTINCT FROM NEW.property_definition_id THEN
          RAISE EXCEPTION 'option does not belong to the property definition'
            USING ERRCODE = '23514', CONSTRAINT = 'inventory_item_property_values_option_membership';
        END IF;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """
  end
end
