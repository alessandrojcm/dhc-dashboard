defmodule Dhc.Inventory.EquipmentCategory do
  @moduledoc """
  Ecto schema for the `equipment_categories` persistence table.

  Vocabulary note: the persistence table is `equipment_categories`; the
  public API contract (see `apps/phoenix/priv/api/openapi.yaml`) refers to
  these as **Inventory Categories** (`InventoryCategory` schema components).
  Payload keys are camelCase (`availableAttributes`, `createdAt`, …); the
  `DhcWeb.InventoryCategoriesJSON` renderer performs the camelCase mapping.

  ## Non-exposed columns

  `attribute_schema` is persisted for forward-compatibility with future
  item-attribute validation slices but is intentionally not part of the
  ALE-105 category contract — it is neither read nor written by this slice.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "equipment_categories" do
    field :name, :string
    field :description, :string
    field :available_attributes, Dhc.Inventory.JsonArray
    # Persisted for future item-attribute validation; not exposed in the
    # ALE-105 category contract.
    field :attribute_schema, Dhc.Inventory.JsonArray

    # Optional aggregate populated by `Dhc.Inventory` read helpers. Not a
    # column — set via `inspect/2` query disables / or assigned directly.
    field :item_count, :integer, virtual: true

    # Production Supabase uses `created_at`/`updated_at` (see the baseline
    # migration `20260512000010_create_inventory.exs`). Use the `timestamps/1`
    # macro with `inserted_at: :created_at` so inserts auto-populate both
    # (the column is NOT NULL); declaring them as plain `field/2` would skip
    # auto-generation. See AGENTS.md "Timestamp column names".
    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end
end
