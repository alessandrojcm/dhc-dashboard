defmodule Dhc.Inventory.MaintenancePeriod do
  @moduledoc """
  Ecto schema for `inventory_maintenance_periods` (ALE-282 expand).

  Retained maintenance fact with at most one open period per item (partial
  unique index on `item_id WHERE ended_at IS NULL`), replacing the legacy
  `inventory_items.out_for_maintenance` boolean. The start/end commands and
  the open-period gate live in `Dhc.Inventory.OperatorItemLifecycle`
  (ALE-284b); an open period is also what makes an item unavailable for
  maintenance reasons in `Dhc.Inventory.ItemProjection`.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "inventory_maintenance_periods" do
    field :item_id, :binary_id
    field :started_at, :utc_datetime_usec
    field :started_by_principal_id, :binary_id
    field :start_reason, :string
    field :ended_at, :utc_datetime_usec
    field :ended_by_principal_id, :binary_id
    field :end_note, :string

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end
end
