defmodule Dhc.Inventory.PropertyDefinition do
  @moduledoc """
  Ecto schema for `inventory_property_definitions` (ALE-282 expand).

  Stable typed property definition owned by one category. Storage only —
  validation and evolution gates land in ALE-283. Not reachable through
  `Dhc.Inventory` yet.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "inventory_property_definitions" do
    field :category_id, :binary_id
    field :label, :string
    field :value_type, :string
    field :required, :boolean, default: false
    field :identifying_position, :integer
    field :retired_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end
end
