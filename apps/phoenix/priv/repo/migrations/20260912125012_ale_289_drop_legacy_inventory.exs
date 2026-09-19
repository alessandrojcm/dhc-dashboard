defmodule Dhc.Repo.Migrations.Ale289DropLegacyInventory do
  @moduledoc """
  ALE-289: nuke the legacy inventory slice. No backfill, no preservation
  (ALE-281): with no inventory data in production, legacy rows are wiped,
  not migrated.

  * Deletes unslugged `inventory_items` rows (legacy quantity/JSON paths
    never minted slugs), then makes `slug` NOT NULL with a full unique
    index (replacing the partial `WHERE slug IS NOT NULL` index).
  * Drops the legacy `inventory_items` columns (`attributes`, `quantity`,
    `photo_url`, `out_for_maintenance`), the `quantity_positive` check,
    and the `out_for_maintenance` index.
  * Drops the legacy `equipment_categories` JSON config columns
    (`available_attributes`, `attribute_schema`).
  * Drops the `inventory_history` table and its data (generic-history
    writes are gone; loan and maintenance history live in their own
    retained tables).
  """

  use Ecto.Migration

  def up do
    # Legacy rows first: nothing below may see an unslugged row, and the
    # NOT NULL constraint requires the table to be clean.
    execute "DELETE FROM inventory_items WHERE slug IS NULL", ""

    drop index(:inventory_items, [:slug], where: "slug IS NOT NULL")

    # Production's Supabase baseline never created this index even though
    # CreateInventory does. A hard drop aborts the Fly release_command.
    drop_if_exists index(:inventory_items, [:out_for_maintenance])

    execute "ALTER TABLE inventory_items DROP CONSTRAINT IF EXISTS quantity_positive", ""

    alter table(:inventory_items) do
      remove :attributes
      remove :quantity
      remove :photo_url
      remove :out_for_maintenance
      modify :slug, :text, null: false
    end

    create unique_index(:inventory_items, [:slug])

    alter table(:equipment_categories) do
      remove :available_attributes
      remove :attribute_schema
    end

    drop table(:inventory_history)
  end

  def down do
    raise "ALE-289 is irreversible: the previous release needs the dropped " <>
            "inventory_history table and legacy columns, so a deploy rollback " <>
            "is schema-incompatible. Recover forward-only — restore from backup " <>
            "or re-run the expand — never via mix ecto.rollback."
  end
end
