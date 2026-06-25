defmodule Dhc.Inventory.EquipmentCategory do
  @moduledoc """
  Read-only Ecto schema for the `equipment_categories` table.

  Maps the **persistence** vocabulary for Inventory equipment types.
  `equipment_categories` is a storage name only; the public/domain name
  exposed by `Dhc.Inventory` read-model helpers uses Inventory language
  (Equipment Category). Keep this schema internal — do not return it
  directly from a controller; build a domain-shaped DTO in the context
  instead.

  The table is created by the baseline Ecto migration
  `20260512000010_create_inventory` and owned by the application.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "equipment_categories" do
    field :name, :string
    field :description, :string
    # JSONB column holding the per-category attribute definitions. The
    # production shape is a JSON array of attribute definition objects
    # (`InventoryAttributeDefinition[]` in the SvelteKit types), so the
    # schema uses `{:array, :map}` to round-trip that shape. The column itself
    # is `:map`/JSONB; Postgres stores arrays in JSONB fine, and `{:array, :map}`
    # is the Ecto type that matches the actual production values.
    field :available_attributes, {:array, :map}, default: []
    field :attribute_schema, :map, default: %{}

    # `timestamps(inserted_at: :created_at)` — the production
    # `equipment_categories` table uses `created_at`/`updated_at`, not
    # `inserted_at`/`updated_at`. The baseline migration mirrors this with
    # `timestamps(type: :timestamptz, inserted_at: :created_at)`. See
    # AGENTS.md `created_at` vs `inserted_at` divergence note.
    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end
end
