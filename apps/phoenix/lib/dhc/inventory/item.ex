defmodule Dhc.Inventory.Item do
  @moduledoc """
  Ecto schema for the `inventory_items` persistence table.

  Vocabulary note: the persistence table is `inventory_items` with
  snake_case columns (`container_id`, `category_id`, `out_for_maintenance`,
  `created_by`, `updated_by`); the public API contract (see
  `apps/phoenix/priv/api/openapi.yaml`) refers to these as **Inventory Items**
  (`InventoryItem` schema components). Payload keys are camelCase
  (`containerId`, `categoryId`, `outForMaintenance`, `photoUrl`, `createdAt`,
  `updatedAt`); the `DhcWeb.InventoryItemsJSON` renderer performs the
  camelCase mapping.

  ## `created_by` / `updated_by`

  Both columns are nullable FKs → `auth.users` (`on_delete: :nothing`).
  The Phoenix context derives `created_by` from the caller's Supabase JWT
  `sub` on insert and `updated_by` on update; neither is ever user-writable
  (the controller does not cast them).

  ## Virtual (non-column) fields

  Read helpers in `Dhc.Inventory` populate these aggregates; they are never
  cast or persisted:

    * `:container` — `%{id, name, parent_container_id}` summary of the
      item's container, or `nil`.
    * `:category` — `%{id, name}` summary of the item's equipment category,
      or `nil`.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "inventory_items" do
    # NOT NULL FK → containers (on_delete: :nothing). Nullable in the schema
    # only so a future "loose item" capability could detach one; the column
    # is NOT NULL today and the context rejects nil on create.
    field :container_id, :binary_id
    field :category_id, :binary_id
    field :attributes, :map, default: %{}
    field :quantity, :integer, default: 1
    field :photo_url, :string
    field :out_for_maintenance, :boolean, default: false
    field :notes, :string
    # Programmatic, derived from the caller's JWT `sub`; never cast.
    field :created_by, :binary_id
    field :updated_by, :binary_id

    # Virtual aggregates populated by `Dhc.Inventory` read helpers.
    field :container, :map, virtual: true
    field :category, :map, virtual: true

    # Production Supabase uses `created_at`/`updated_at` (see the baseline
    # migration `20260512000010_create_inventory.exs`). Use `timestamps/1`
    # with `inserted_at: :created_at` so inserts auto-populate both (the
    # column is NOT NULL).
    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end
end
