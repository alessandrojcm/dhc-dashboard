defmodule Dhc.Repo.Migrations.Ale289RemoveLegacyInventoryTriggers do
  @moduledoc """
  Remove Supabase-era inventory triggers left behind by ALE-289.

  Production inherited these objects from the frozen Supabase migration
  history, while a fresh Ecto database never had them. ALE-289 removed the
  columns and table used by their trigger functions, leaving category and item
  writes to fail at runtime. Every drop is conditional so the migration also
  runs against fresh databases.
  """

  use Ecto.Migration

  def up do
    execute "DROP TRIGGER IF EXISTS validate_item_attributes_trigger ON public.inventory_items"
    execute "DROP TRIGGER IF EXISTS create_inventory_history_trigger ON public.inventory_items"
    execute "DROP TRIGGER IF EXISTS category_schema_trigger ON public.equipment_categories"

    execute "DROP FUNCTION IF EXISTS public.validate_item_attributes()"
    execute "DROP FUNCTION IF EXISTS public.create_inventory_history()"
    execute "DROP FUNCTION IF EXISTS public.update_category_schema()"
    execute "DROP FUNCTION IF EXISTS public.generate_attribute_schema(jsonb)"
  end

  def down do
    raise "legacy inventory triggers reference storage removed by ALE-289 and cannot be restored"
  end
end
