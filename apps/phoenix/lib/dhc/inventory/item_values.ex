defmodule Dhc.Inventory.ItemValues do
  @moduledoc """
  ALE-284a: typed item property values.

  Owns the value half of the operator item seam: reloading a category's
  live definitions inside the caller's transaction, validating a supplied
  value set against them, and projecting stored values back for reads.

  Validation rules (spec ALE-280 stories 6, 22, 23; ALE-278 resolution):

    * Empty or whitespace-only text is **absence** (no value row); boolean
      `false` is a real value. There are no defaults.
    * A supplied value must match its definition's `value_type`; a
      single-select value must be a live option of that same definition.
    * A required definition with no value fails with `:required`.
    * Errors are per definition, so an operator sees every field to fix.

  Definitions **and their options** are read with `FOR SHARE` so a concurrent
  evolution command (`Dhc.Inventory.Structure.update_definition/2` or
  `retire_option/1`, both of which lock `FOR UPDATE`) cannot change
  requiredness, type, or option membership underneath a validated write.
  """

  import Ecto.Query

  alias Dhc.Inventory.ItemPropertyValue
  alias Dhc.Inventory.PropertyDefinition
  alias Dhc.Inventory.PropertyOption
  alias Dhc.Repo

  @type definition :: PropertyDefinition.t()

  @type error_reason ::
          :required
          | :type_mismatch
          | :unknown_option
          | :retired_option
          | :retired_definition
          | :unknown_definition

  @type value_view :: %{
          definition_id: String.t(),
          definition_label: String.t(),
          value_type: String.t(),
          identifying_position: non_neg_integer() | nil,
          text: String.t() | nil,
          decimal: Decimal.t() | nil,
          boolean: boolean() | nil,
          option_id: String.t() | nil,
          option_label: String.t() | nil
        }

  @doc """
  Load a category's definitions (with their options) for validation.

  Must run inside the caller's transaction: the rows are locked `FOR SHARE`
  so requiredness, type, and option membership cannot change concurrently.
  """
  @spec load_definitions(String.t()) :: [definition()]
  def load_definitions(category_id) when is_binary(category_id) do
    definitions =
      from(d in PropertyDefinition,
        where: d.category_id == ^category_id,
        lock: "FOR SHARE"
      )
      |> Repo.all()

    options = options_by_definition(Enum.map(definitions, & &1.id))

    definitions
    |> Enum.map(fn %PropertyDefinition{id: id} = definition ->
      %PropertyDefinition{definition | options: Map.get(options, id, [])}
    end)
    |> Enum.sort_by(&definition_order/1)
  end

  @doc """
  Validate a supplied value set against `definitions`.

  Returns insertable row attributes (without `item_id`) or a map of
  definition id to `t:error_reason/0`.
  """
  @spec validate([definition()], map()) ::
          {:ok, [map()]} | {:error, %{String.t() => error_reason()}}
  def validate(definitions, supplied) when is_list(definitions) and is_map(supplied) do
    normalized = normalize_supplied(supplied)

    {rows, errors} =
      definitions
      |> Enum.reduce({[], %{}}, fn definition, acc ->
        apply_definition(definition, Map.fetch(normalized, definition.id), acc)
      end)
      |> resolve_options(options_index(definitions))

    case Map.merge(errors, unknown_definition_errors(definitions, normalized)) do
      empty when empty == %{} -> {:ok, Enum.reverse(rows)}
      merged -> {:error, merged}
    end
  end

  @doc """
  Replace every stored value of `item_id` with `rows`.
  """
  @spec replace_all(String.t(), [map()]) :: :ok
  def replace_all(item_id, rows) when is_binary(item_id) and is_list(rows) do
    from(v in ItemPropertyValue, where: v.item_id == ^item_id) |> Repo.delete_all()
    insert_all(item_id, rows)
  end

  @doc """
  Insert `rows` as values of `item_id`.
  """
  @spec insert_all(String.t(), [map()]) :: :ok
  def insert_all(_item_id, []), do: :ok

  def insert_all(item_id, rows) when is_binary(item_id) and is_list(rows) do
    now = DateTime.utc_now()

    entries =
      Enum.map(
        rows,
        &Map.merge(&1, %{item_id: item_id, created_at: now, updated_at: now})
      )

    Repo.insert_all(ItemPropertyValue, entries)
    :ok
  end

  @doc """
  Stored values of `item_id`, ordered by identifying position then label.

  Includes values whose definition or option has been retired so archived
  and historical facts stay displayable (ALE-278).
  """
  @spec list_values(String.t()) :: [value_view()]
  def list_values(item_id) when is_binary(item_id) do
    from(v in ItemPropertyValue,
      join: d in PropertyDefinition,
      on: d.id == v.property_definition_id,
      left_join: o in PropertyOption,
      on: o.id == v.option_id,
      where: v.item_id == ^item_id,
      order_by: [
        asc: fragment("? IS NULL", d.identifying_position),
        asc: d.identifying_position,
        asc: fragment("lower(?)", d.label)
      ],
      select: %{
        definition_id: d.id,
        definition_label: d.label,
        value_type: d.value_type,
        identifying_position: d.identifying_position,
        text: v.text_value,
        decimal: v.decimal_value,
        boolean: v.boolean_value,
        option_id: v.option_id,
        option_label: o.label
      }
    )
    |> Repo.all()
  end

  # ── Per-definition validation ───────────────────────────────────

  defp apply_definition(%PropertyDefinition{retired_at: nil} = definition, supplied, acc) do
    apply_live_definition(definition, supplied, acc)
  end

  defp apply_definition(%PropertyDefinition{}, :error, acc), do: acc

  defp apply_definition(%PropertyDefinition{} = definition, {:ok, raw}, acc) do
    if absent?(raw),
      do: acc,
      else: put_error(acc, definition.id, :retired_definition)
  end

  defp apply_live_definition(%PropertyDefinition{} = definition, :error, acc) do
    if definition.required, do: put_error(acc, definition.id, :required), else: acc
  end

  defp apply_live_definition(%PropertyDefinition{} = definition, {:ok, raw}, acc) do
    case cast_value(definition, raw) do
      :absent -> apply_live_definition(definition, :error, acc)
      {:ok, row} -> put_row(acc, Map.put(row, :property_definition_id, definition.id))
      {:error, reason} -> put_error(acc, definition.id, reason)
    end
  end

  defp put_row({rows, errors}, row), do: {[row | rows], errors}

  defp put_error({rows, errors}, definition_id, reason),
    do: {rows, Map.put(errors, definition_id, reason)}

  defp unknown_definition_errors(definitions, normalized) do
    known = MapSet.new(definitions, & &1.id)

    normalized
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(known, &1))
    |> Map.new(&{&1, :unknown_definition})
  end

  # ── Casting ─────────────────────────────────────────────────────

  defp cast_value(%PropertyDefinition{value_type: type}, raw) when type != "boolean" do
    if absent?(raw), do: :absent, else: cast_present(type, raw)
  end

  defp cast_value(%PropertyDefinition{value_type: "boolean"}, raw), do: cast_boolean(raw)

  defp cast_present("text", raw) when is_binary(raw), do: {:ok, %{text_value: String.trim(raw)}}
  defp cast_present("text", _raw), do: {:error, :type_mismatch}

  defp cast_present("decimal", raw), do: cast_decimal(raw)

  defp cast_present("single_select", raw) when is_binary(raw), do: {:ok, %{option_id: raw}}
  defp cast_present("single_select", _raw), do: {:error, :type_mismatch}

  defp cast_decimal(%Decimal{} = raw), do: {:ok, %{decimal_value: raw}}
  defp cast_decimal(raw) when is_integer(raw), do: {:ok, %{decimal_value: Decimal.new(raw)}}

  defp cast_decimal(raw) when is_float(raw),
    do: {:ok, %{decimal_value: Decimal.from_float(raw)}}

  defp cast_decimal(raw) when is_binary(raw) do
    case Decimal.parse(String.trim(raw)) do
      {decimal, ""} -> {:ok, %{decimal_value: decimal}}
      _ -> {:error, :type_mismatch}
    end
  end

  defp cast_decimal(_raw), do: {:error, :type_mismatch}

  defp cast_boolean(raw) when is_boolean(raw), do: {:ok, %{boolean_value: raw}}
  defp cast_boolean(nil), do: :absent
  defp cast_boolean("true"), do: {:ok, %{boolean_value: true}}
  defp cast_boolean("false"), do: {:ok, %{boolean_value: false}}

  defp cast_boolean(raw) when is_binary(raw),
    do: if(String.trim(raw) == "", do: :absent, else: {:error, :type_mismatch})

  defp cast_boolean(_raw), do: {:error, :type_mismatch}

  # Empty text is absence; `false` never is.
  defp absent?(nil), do: true
  defp absent?(raw) when is_binary(raw), do: String.trim(raw) == ""
  defp absent?(_raw), do: false

  # ── Option membership ───────────────────────────────────────────

  # Single-select rows carry a raw option id after casting. Membership and
  # retirement get their own per-definition reasons rather than a generic
  # type mismatch.
  defp resolve_options({rows, errors}, options) do
    rows
    |> Enum.reverse()
    |> Enum.reduce({[], errors}, fn row, acc -> resolve_option_row(row, options, acc) end)
  end

  defp resolve_option_row(
         %{option_id: option_id, property_definition_id: definition_id} = row,
         options,
         acc
       ) do
    case Map.fetch(options, {definition_id, option_id}) do
      {:ok, %PropertyOption{retired_at: nil}} -> put_row(acc, row)
      {:ok, %PropertyOption{}} -> put_error(acc, definition_id, :retired_option)
      :error -> put_error(acc, definition_id, :unknown_option)
    end
  end

  defp resolve_option_row(row, _options, acc), do: put_row(acc, row)

  defp options_index(definitions) do
    for %PropertyDefinition{id: definition_id, options: options} <- definitions,
        %PropertyOption{id: option_id} = option <- options,
        into: %{},
        do: {{definition_id, option_id}, option}
  end

  defp options_by_definition([]), do: %{}

  defp options_by_definition(definition_ids) do
    # Locked with the definitions: `retire_option/1` takes `FOR UPDATE`, so
    # without this an option could retire between validation and the value
    # insert, leaving an active item pointing at a retired option (its
    # active-value gate cannot see the uncommitted row).
    from(o in PropertyOption,
      where: o.property_definition_id in ^definition_ids,
      order_by: [asc: o.position, asc: o.label],
      lock: "FOR SHARE"
    )
    |> Repo.all()
    |> Enum.group_by(& &1.property_definition_id)
  end

  defp definition_order(%PropertyDefinition{identifying_position: position, label: label}) do
    {if(is_nil(position), do: 1, else: 0), position || 0, String.downcase(label || "")}
  end

  # ── Supplied-attribute normalization ────────────────────────────

  defp normalize_supplied(supplied) do
    Map.new(supplied, fn {key, value} -> {to_string(key), value} end)
  end
end
