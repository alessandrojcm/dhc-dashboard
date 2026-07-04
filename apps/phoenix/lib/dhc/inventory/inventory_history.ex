defmodule Dhc.Inventory.InventoryHistory do
  @moduledoc """
  Ecto schema for the `inventory_history` persistence table.

  One row per audited item change. `action` is the Postgres `inventory_action`
  enum (`created`, `moved`, `updated`, `maintenance_out`, `maintenance_in`).
  `old_container_id` / `new_container_id` are populated for `moved` and are
  `nil` for `created`/`updated`. `item_id` is `on_delete: :delete_all`, so
  deleting an item cascades its history rows away — the ALE-107 item slice
  therefore records no dedicated `deleted` history row on delete (it would be
  cascade-wiped and is pointless).

  Vocabulary note: the persistence table is `inventory_history` with
  snake_case columns (`old_container_id`, `new_container_id`, `changed_by`);
  the public API contract refers to these as **InventoryItemHistory** schema
  components. Payload keys are camelCase (`itemId`, `oldContainerId`,
  `newContainerId`, `oldContainer`, `newContainer`, `changedBy`, `createdAt`);
  the `DhcWeb.InventoryItemsJSON` renderer performs the mapping.

  ## Virtual (non-column) fields

  Read helpers in `Dhc.Inventory` populate these summaries; they are never
  cast or persisted:

    * `:old_container` — `%{id, name}` summary, or `nil`.
    * `:new_container` — `%{id, name}` summary, or `nil`.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  @type action :: :created | :moved | :updated | :maintenance_out | :maintenance_in

  # `:maintenance_out` is recorded when an item is flagged out for maintenance;
  # `:maintenance_in` when it returns. Both use nil old/new container ids
  # (maintenance is not a container move).

  schema "inventory_history" do
    field :item_id, :binary_id
    # `inventory_action` Postgres enum. Ecto stores the atom/string verbatim;
    # we validate membership at the changeset boundary in `Dhc.Inventory`.
    field :action, Ecto.Enum,
      values: [:created, :moved, :updated, :maintenance_out, :maintenance_in]

    field :old_container_id, :binary_id
    field :new_container_id, :binary_id
    # Programmatic, derived from the caller's JWT `sub`; never cast.
    field :changed_by, :binary_id
    field :notes, :string

    # Virtual aggregates populated by `Dhc.Inventory` read helpers.
    field :old_container, :map, virtual: true
    field :new_container, :map, virtual: true

    # Virtual item summary `%{id, attributes}` — populated only by the global
    # history read helper (`Dhc.Inventory.ItemHistory.list_history/1`); the
    # per-item history helper leaves it nil because the caller already holds
    # the item id from the path.
    field :item, :map, virtual: true

    # The migration declares only `created_at` (no `updated_at`); mirror that
    # here so Ecto does not try to write/read an `updated_at` column.
    field :created_at, :utc_datetime_usec
  end
end
