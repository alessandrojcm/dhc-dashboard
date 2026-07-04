defmodule Dhc.Inventory.JsonArray do
  @moduledoc """
  Ecto type for a `jsonb` column that stores a JSON array of objects
  (e.g. `equipment_categories.available_attributes`).

  The baseline migration declares these columns as `:map` with a default of
  `'{}'::jsonb`, but the seeded rows and all writes store JSON **arrays** of
  attribute-definition objects. Ecto's built-in `:map` type only round-trips
  maps, so a list would be rejected. This custom type treats the column as a
  nullable list:

    * `cast/1` — accepts a list (of maps) or `nil`; anything else errors.
    * `load/1` — normalizes the decoded jsonb into an Elixir list. An empty
      object (`%{}`, the column's default for rows written before the API)
      is treated as `[]`; `nil` stays `nil`.
    * `dump/1` — passes a list (or `nil`) straight through to Postgrex, which
      encodes it back to jsonb.

  The elements themselves are left untouched: attribute definition maps keep
  whatever keys the writer sent (the API contract uses camelCase keys
  `name`/`label`/`type`/`required`/`options`/`defaultValue`). This type does
  not reshape element keys.
  """

  use Ecto.Type

  @impl Ecto.Type
  def type, do: :map

  @impl Ecto.Type
  def cast(nil), do: {:ok, nil}

  def cast(list) when is_list(list), do: {:ok, list}

  def cast(_), do: {:error, [message: "must be an array"]}

  @impl Ecto.Type
  def load(nil), do: {:ok, nil}

  # The column default is `'{}'::jsonb`; treat the empty object as an empty
  # array so legacy rows render as "no attributes" rather than a non-list.
  def load(%{} = map) when map == %{}, do: {:ok, []}

  def load(list) when is_list(list), do: {:ok, list}

  def load(_), do: :error

  @impl Ecto.Type
  def dump(nil), do: {:ok, nil}

  def dump(list) when is_list(list), do: {:ok, list}

  def dump(_), do: :error

  @impl Ecto.Type
  def embed_as(_), do: :self
end
