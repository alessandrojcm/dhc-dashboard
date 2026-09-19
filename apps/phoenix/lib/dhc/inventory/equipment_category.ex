defmodule Dhc.Inventory.EquipmentCategory do
  @moduledoc """
  Ecto schema for the `equipment_categories` persistence table.

  Vocabulary note: the persistence table is `equipment_categories`; the
  public API contract (see `apps/phoenix/priv/api/openapi.yaml`) refers to
  these as **Inventory Categories** (`InventoryCategory` schema components).
  Payload keys are camelCase (`itemCount`, `createdAt`, …); the
  `DhcWeb.InventoryCategoriesJSON` renderer performs the camelCase mapping.
  Typed property definitions live in their own tables behind
  `Dhc.Inventory.Structure` — ALE-289 dropped the legacy
  `available_attributes` / `attribute_schema` JSON config columns.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "equipment_categories" do
    field :name, :string
    field :description, :string
    # ALE-282 target column: set when the category is archived instead of
    # hard-deleted. ALE-283b owns the archive/restore commands; the field
    # exists here so structure reads can distinguish active rows.
    field :archived_at, :utc_datetime_usec

    # Optional aggregate populated by `Dhc.Inventory` read helpers. Not a
    # column — set via `inspect/2` query disables / or assigned directly.
    field :item_count, :integer, virtual: true

    has_many :property_definitions, Dhc.Inventory.PropertyDefinition, foreign_key: :category_id

    # Production Supabase uses `created_at`/`updated_at` (see the baseline
    # migration `20260512000010_create_inventory.exs`). Use the `timestamps/1`
    # macro with `inserted_at: :created_at` so inserts auto-populate both
    # (the column is NOT NULL); declaring them as plain `field/2` would skip
    # auto-generation. See AGENTS.md "Timestamp column names".
    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end
end
