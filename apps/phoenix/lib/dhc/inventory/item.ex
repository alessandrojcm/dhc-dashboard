defmodule Dhc.Inventory.Item do
  @moduledoc """
  Ecto schema for the `inventory_items` persistence table.

  Vocabulary note: the persistence table is `inventory_items` with
  snake_case columns (`container_id`, `category_id`, `created_by`,
  `updated_by`); the public API contract (see
  `apps/phoenix/priv/api/openapi.yaml`) refers to these as **Inventory Items**
  (`InventoryOperatorItem` schema components). Payload keys are camelCase
  (`containerId`, `categoryId`, `createdAt`, `updatedAt`); the
  `DhcWeb.InventoryItemsJSON` renderer performs the camelCase mapping.

  ## `created_by` / `updated_by`

  Both columns are nullable FKs → `auth.users` (`on_delete: :nothing`).
  The Phoenix context derives `created_by` from the caller's session
  principal id on insert and `updated_by` on update; neither is ever
  user-writable (the controller does not cast them).

  ## Target columns

  One row is one physical unit:

    * `:slug` — immutable, server-minted, human-readable identity
      (`item-000001`) drawn from `inventory_item_slug_seq`. Unique where
      present; stable across category changes. ALE-289 deleted the legacy
      unslugged rows and made it NOT NULL.
    * `:archived_at` / `:archived_by_principal_id` — set when the item is
      archived instead of hard-deleted. ALE-284b owns those commands; the
      fields exist here so target reads can tell active rows apart.

  ALE-289 dropped the legacy columns (`quantity`, `photo_url`,
  `attributes`, `out_for_maintenance`) and the `inventory_history` table:
  labels are derived, availability is projected, and maintenance periods
  and loans are retained facts in their own tables.

  ## Virtual (non-column) fields

  Read helpers in `Dhc.Inventory` populate these aggregates; they are never
  cast or persisted:

    * `:container` — `%{id, name, parent_container_id}` summary of the
      item's container, or `nil`.
    * `:category` — `%{id, name}` summary of the item's equipment category,
      or `nil`.
    * `:label` — server-derived display label (category plus ordered
      identifying property values, slug as fallback). Never stored; see
      `Dhc.Inventory.ItemProjection`.
    * `:values` — typed property value views for the item's category.
    * `:availability` — `%{available?: boolean, status: atom}` recomputed on
      every read from archive state, the open maintenance period, and
      approved/checked-out loans. Never a stored flag.
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
    field :notes, :string
    # Programmatic, derived from the caller's session principal; never cast.
    field :created_by, :binary_id
    field :updated_by, :binary_id

    # Target columns.
    field :slug, :string
    field :archived_at, :utc_datetime_usec
    field :archived_by_principal_id, :binary_id

    # Virtual aggregates populated by `Dhc.Inventory` read helpers.
    field :container, :map, virtual: true
    field :category, :map, virtual: true
    field :label, :string, virtual: true
    field :values, {:array, :map}, virtual: true, default: []
    field :availability, :map, virtual: true

    # Production Supabase uses `created_at`/`updated_at` (see the baseline
    # migration `20260512000010_create_inventory.exs`). Use `timestamps/1`
    # with `inserted_at: :created_at` so inserts auto-populate both (the
    # column is NOT NULL).
    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end
end
