defmodule Dhc.Inventory.PageParams do
  @moduledoc """
  Shared pagination-option parsing for inventory list reads.

  `MemberCatalog`, `MemberLoans` and `OperatorItemList` share the same limit /
  direction / blank-string vocabulary; only the default direction differs
  (slug-asc vs newest-first).
  """

  @allowed_limits [10, 25, 50, 100]
  @default_limit 25
  @allowed_directions ~w(asc desc)

  @spec parse_limit(term()) :: {:ok, pos_integer()} | {:error, :invalid_limit}
  def parse_limit(nil), do: {:ok, @default_limit}
  def parse_limit(""), do: {:ok, @default_limit}
  def parse_limit(limit) when limit in @allowed_limits, do: {:ok, limit}

  def parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, ""} -> parse_limit(parsed)
      _other -> {:error, :invalid_limit}
    end
  end

  def parse_limit(_limit), do: {:error, :invalid_limit}

  @spec parse_direction(term(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_direction}
  def parse_direction(raw, default \\ "asc")

  def parse_direction(nil, default), do: {:ok, default}
  def parse_direction("", default), do: {:ok, default}

  def parse_direction(direction, _default) when is_binary(direction) do
    if direction in @allowed_directions,
      do: {:ok, direction},
      else: {:error, :invalid_direction}
  end

  def parse_direction(_direction, _default), do: {:error, :invalid_direction}

  @doc "Blank or non-string input is `nil`; otherwise the trimmed string."
  @spec blank_to_nil(term()) :: String.t() | nil
  def blank_to_nil(nil), do: nil

  def blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def blank_to_nil(_value), do: nil
end
