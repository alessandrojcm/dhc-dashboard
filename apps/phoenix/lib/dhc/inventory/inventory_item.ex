defmodule Dhc.Inventory.InventoryItem do
  @moduledoc """
  Read-only Ecto schema for the `inventory_items` table.

  Maps the **persistence** vocabulary for Inventory items. `inventory_items`
  is a storage name only; the public/domain name exposed by `Dhc.Inventory`
  read-model helpers uses Inventory language (Inventory Item). Keep this
  schema internal — do not return it directly from a controller; build a
  domain-shaped DTO in the context instead.

  The table is created by the baseline Ecto migration
  `20260512000010_create_inventory` and owned by the application.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "inventory_items" do
    field :container_id, :binary_id
    field :category_id, :binary_id
    # JSONB column holding per-item attribute values (e.g. brand, size).
    field :attributes, :map, default: %{}
    field :quantity, :integer, default: 1
    field :photo_url, :string
    field :out_for_maintenance, :boolean, default: false
    field :notes, :string
    # `created_by` / `updated_by` reference `auth.users(id)` (Supabase-owned);
    # read-only here.
    field :created_by, :binary_id
    field :updated_by, :binary_id

    # `timestamps(inserted_at: :created_at)` — the production `inventory_items`
    # table uses `created_at`/`updated_at`, not `inserted_at`/`updated_at`.
    # The baseline migration mirrors this with
    # `timestamps(type: :timestamptz, inserted_at: :created_at)`. The
    # Inventory Item list read (ALE-99) orders by `created_at desc, id desc`.
    # See AGENTS.md `created_at` vs `inserted_at` divergence note.
    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end
end