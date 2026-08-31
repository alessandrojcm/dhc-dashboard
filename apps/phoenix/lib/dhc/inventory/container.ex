defmodule Dhc.Inventory.Container do
  @moduledoc """
  Ecto schema for the `containers` persistence table.

  Vocabulary note: the persistence table is `containers` with
  `parent_container_id`; the public API contract (see
  `apps/phoenix/priv/api/openapi.yaml`) refers to these as **Inventory
  Containers** (`InventoryContainer` / `InventoryContainerDetail` schema
  components). Payload keys are camelCase (`parentContainerId`,
  `parentContainer`, `childContainers`, `itemCount`, `createdAt`); the
  `DhcWeb.InventoryContainersJSON` renderer performs the camelCase mapping.

  ## Virtual (non-column) fields

  Read helpers in `Dhc.Inventory` populate these aggregates; they are never
  cast or persisted:

    * `:item_count` — number of `inventory_items` rows directly in this
      container.
    * `:parent_container` — `%{id, name}` summary of the parent, or `nil`.
    * `:child_containers` — list of `%{id, name}` child summaries.
    * `:items` — list of minimal item summaries
      (`%{id, quantity, out_for_maintenance, category}`) for the detail view.

  ## `created_by`

  The column is NOT NULL and references `auth.users`. The Phoenix context sets
  it from the caller's Supabase JWT `sub` (`conn.assigns.current_user.sub`)
  on insert; it is never user-writable and is left untouched on update.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "containers" do
    field :name, :string
    field :description, :string
    field :parent_container_id, :binary_id
    # Optimistic-concurrency version witness (ADR 0023); bumped on every
    # update via `Ecto.Changeset.optimistic_lock/3`, never client-writable.
    field :lock_version, :integer, default: 1
    # NOT NULL FK → auth.users. Set programmatically from the JWT `sub`; never
    # cast from request params.
    field :created_by, :binary_id

    # Virtual aggregates populated by `Dhc.Inventory` read helpers.
    field :item_count, :integer, virtual: true
    field :parent_container, :map, virtual: true
    field :child_containers, {:array, :map}, virtual: true, default: []
    field :items, {:array, :map}, virtual: true, default: []

    # Production Supabase uses `created_at`/`updated_at` (see the baseline
    # migration `20260512000010_create_inventory.exs`). Use the `timestamps/1`
    # macro with `inserted_at: :created_at` so inserts auto-populate both
    # (the column is NOT NULL).
    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end
end
