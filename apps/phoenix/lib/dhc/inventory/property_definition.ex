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

    field :options, {:array, :map}, virtual: true, default: []

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  @value_types ~w(text decimal boolean single_select)

  @doc false
  def changeset(definition, attrs) do
    definition
    |> Ecto.Changeset.cast(attrs, [
      :category_id,
      :label,
      :value_type,
      :required,
      :identifying_position
    ])
    |> Ecto.Changeset.validate_required([:category_id, :label, :value_type])
    |> Ecto.Changeset.validate_length(:label, min: 1, max: 100)
    |> Ecto.Changeset.validate_inclusion(:value_type, @value_types)
    |> Ecto.Changeset.validate_number(:identifying_position,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 1_000_000
    )
    |> Ecto.Changeset.unique_constraint(:label,
      name: :inventory_property_definitions_category_label_unique
    )
    |> Ecto.Changeset.unique_constraint(:identifying_position,
      name: :inventory_property_definitions_category_identifying_position_unique
    )
  end

  @doc false
  def value_types, do: @value_types
end
