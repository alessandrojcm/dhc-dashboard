defmodule Dhc.Inventory.InventoryActivity do
  @moduledoc """
  Read-only Ecto schema for the `inventory_history` table.

  Maps the **persistence** vocabulary for Inventory Activity records.
  `inventory_history` is a storage name only; the public/domain name exposed
  by `Dhc.Inventory` read-model helpers uses Inventory language (Inventory
  Activity). Keep this schema internal — do not return it directly from a
  controller; build a domain-shaped DTO in the context instead.

  The table is created by the baseline Ecto migration
  `20260512000010_create_inventory` and owned by the application.

  ## Timestamps

  Unlike the other `Dhc.Inventory.*` schemas (which use plain
  `timestamps(type: :utc_datetime)` and therefore `inserted_at`/`updated_at`),
  `inventory_history` has a single `created_at` column (no `updated_at` —
  history rows are immutable). The baseline migration adds it explicitly as
  `add :created_at, :timestamptz, default: fragment("NOW()")`, so this schema
  declares a standalone `field :created_at, :utc_datetime` rather than
  calling `timestamps/1`. This mirrors the production Supabase shape and is
  the column the ALE-95 activity feed orders by.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "inventory_history" do
    field :item_id, :binary_id
    # Postgres `inventory_action` enum — declared as :string like the other
    # enum columns in this codebase (see `Dhc.Workshops.Workshop` `status`).
    field :action, :string
    field :old_container_id, :binary_id
    field :new_container_id, :binary_id
    # `changed_by` references `auth.users(id)` (Supabase-owned); read-only.
    field :changed_by, :binary_id
    field :notes, :string
    field :created_at, :utc_datetime
  end
end
