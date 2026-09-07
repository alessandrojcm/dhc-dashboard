defmodule Dhc.Inventory.PropertyOption do
  @moduledoc """
  Ecto schema for `inventory_property_options` (ALE-282 expand).

  Stable single-select option owned by one property definition. Storage only —
  administration lands in ALE-283. Not reachable through `Dhc.Inventory` yet.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "inventory_property_options" do
    field :property_definition_id, :binary_id
    field :label, :string
    field :position, :integer, default: 0
    field :retired_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end
end
