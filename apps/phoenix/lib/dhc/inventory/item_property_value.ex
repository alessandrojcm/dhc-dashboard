defmodule Dhc.Inventory.ItemPropertyValue do
  @moduledoc """
  Ecto schema for `inventory_item_property_values` (ALE-282 expand).

  Typed value row keyed by `(item_id, property_definition_id)` with exactly
  one of `text_value`, `decimal_value`, `boolean_value`, or `option_id` set
  (enforced by a database check). Empty text has no row; `false` is present.
  Storage only — validation lands in ALE-283/284. Not reachable through
  `Dhc.Inventory` yet.
  """

  use Ecto.Schema

  @primary_key false

  schema "inventory_item_property_values" do
    field :item_id, :binary_id, primary_key: true
    field :property_definition_id, :binary_id, primary_key: true
    field :text_value, :string
    field :decimal_value, :decimal
    field :boolean_value, :boolean
    field :option_id, :binary_id

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end
end
