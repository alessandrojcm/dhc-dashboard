defmodule Dhc.Repo.Migrations.Ale292TypedValueBackstops do
  @moduledoc """
  ALE-292: remaining typed-value backstops.

  ALE-282 already enforces exactly-one value column. This adds the
  remaining checks the HTTP seam cannot express: the stored column must
  match the definition's `value_type`, and a single-select `option_id`
  must belong to that definition.
  """

  use Ecto.Migration

  def up do
    execute """
    CREATE FUNCTION inventory_item_property_values_reject_type_mismatch() RETURNS trigger AS $$
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

    execute """
    CREATE TRIGGER inventory_item_property_values_type_match
      BEFORE INSERT OR UPDATE ON inventory_item_property_values
      FOR EACH ROW EXECUTE FUNCTION inventory_item_property_values_reject_type_mismatch()
    """

    execute """
    CREATE FUNCTION inventory_property_definitions_reject_incompatible_values() RETURNS trigger AS $$
    BEGIN
      IF NEW.value_type IS DISTINCT FROM OLD.value_type AND EXISTS (
        SELECT 1
          FROM inventory_item_property_values value
         WHERE value.property_definition_id = NEW.id
           AND (
             (NEW.value_type = 'text' AND value.text_value IS NULL) OR
             (NEW.value_type = 'decimal' AND value.decimal_value IS NULL) OR
             (NEW.value_type = 'boolean' AND value.boolean_value IS NULL) OR
             (NEW.value_type = 'single_select' AND value.option_id IS NULL)
           )
      ) THEN
        RAISE EXCEPTION 'definition value_type does not match existing values'
          USING ERRCODE = '23514', CONSTRAINT = 'inventory_item_property_values_value_type_match';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER inventory_property_definitions_value_type_match
      BEFORE UPDATE OF value_type ON inventory_property_definitions
      FOR EACH ROW EXECUTE FUNCTION inventory_property_definitions_reject_incompatible_values()
    """

    execute """
    CREATE FUNCTION inventory_property_options_reject_foreign_values() RETURNS trigger AS $$
    BEGIN
      IF NEW.property_definition_id IS DISTINCT FROM OLD.property_definition_id AND EXISTS (
        SELECT 1
          FROM inventory_item_property_values value
         WHERE value.option_id = NEW.id
           AND value.property_definition_id IS DISTINCT FROM NEW.property_definition_id
      ) THEN
        RAISE EXCEPTION 'option does not belong to the property definition'
          USING ERRCODE = '23514', CONSTRAINT = 'inventory_item_property_values_option_membership';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER inventory_property_options_membership
      BEFORE UPDATE OF property_definition_id ON inventory_property_options
      FOR EACH ROW EXECUTE FUNCTION inventory_property_options_reject_foreign_values()
    """
  end

  def down do
    execute "DROP TRIGGER inventory_property_options_membership ON inventory_property_options"
    execute "DROP FUNCTION inventory_property_options_reject_foreign_values()"
    execute "DROP TRIGGER inventory_property_definitions_value_type_match ON inventory_property_definitions"
    execute "DROP FUNCTION inventory_property_definitions_reject_incompatible_values()"
    execute "DROP TRIGGER inventory_item_property_values_type_match ON inventory_item_property_values"
    execute "DROP FUNCTION inventory_item_property_values_reject_type_mismatch()"
  end
end
