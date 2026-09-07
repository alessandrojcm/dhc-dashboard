defmodule Dhc.Inventory.Structure do
  @moduledoc """
  ALE-283a: operator administration of the inventory taxonomy.

  Owns typed property definitions and single-select options behind the
  `Dhc.Inventory` seam. Categories and containers keep their existing
  slices; archive/restore for categories and the container hierarchy
  guards land in ALE-283b. Viewer contracts land in ALE-283c.

  Evolution gates (spec ALE-280 stories 18–21):

    * `value_type` is immutable once the definition is used (any value
      row or any option row references it).
    * Making a definition required is blocked until every active
      (non-archived) item in the category holds a valid value.
    * Retiring a definition or option is blocked while active values
      reference it. Archived-only references may retire; the rows stay
      displayable in history. Callers must clear or migrate active
      values first — retire never cascades.
    * Empty text is absence (no value row); boolean `false` is a real
      value. There are no defaults.
  """

  import Ecto.Query

  alias Dhc.Inventory.EquipmentCategory
  alias Dhc.Inventory.ItemPropertyValue
  alias Dhc.Inventory.PropertyDefinition
  alias Dhc.Inventory.PropertyOption
  alias Dhc.Repo

  @type definition :: PropertyDefinition.t()
  @type option :: PropertyOption.t()

  # ── Definitions: reads ──────────────────────────────────────────

  @spec list_definitions(String.t()) :: [definition()]
  def list_definitions(category_id) when is_binary(category_id) do
    from(d in PropertyDefinition,
      where: d.category_id == ^category_id,
      order_by: [asc: d.label]
    )
    |> Repo.all()
    |> Enum.map(&attach_options/1)
    |> sort_definitions()
  end

  @spec get_definition(String.t()) :: {:ok, definition()} | {:error, :not_found}
  def get_definition(id) when is_binary(id) do
    case Repo.get(PropertyDefinition, id) do
      nil -> {:error, :not_found}
      %PropertyDefinition{} = definition -> {:ok, attach_options(definition)}
    end
  end

  # ── Definitions: writes ─────────────────────────────────────────

  @spec create_definition(String.t(), map()) ::
          {:ok, definition()}
          | {:error, :not_found}
          | {:error, :conflict, Ecto.Changeset.t()}
          | {:error, Ecto.Changeset.t()}
  def create_definition(category_id, attrs)
      when is_binary(category_id) and is_map(attrs) do
    case Repo.get(EquipmentCategory, category_id) do
      nil ->
        {:error, :not_found}

      %EquipmentCategory{} ->
        normalized =
          normalize_definition_attrs(attrs)
          |> Map.put("category_id", category_id)

        %PropertyDefinition{}
        |> PropertyDefinition.changeset(normalized)
        |> Repo.insert()
        |> handle_definition_result()
    end
  end

  @spec update_definition(String.t(), map()) ::
          {:ok, definition()}
          | {:error, :not_found}
          | {:error, :type_immutable}
          | {:error, :required_blocked, %{item_ids: [String.t()]}}
          | {:error, :conflict, Ecto.Changeset.t()}
          | {:error, Ecto.Changeset.t()}
  def update_definition(id, attrs) when is_binary(id) and is_map(attrs) do
    Repo.transaction(fn -> locked_update_definition(id, attrs) end)
    |> translate_update_result()
  end

  defp locked_update_definition(id, attrs) do
    case Repo.get(PropertyDefinition, id, lock: "FOR UPDATE") do
      nil -> Repo.rollback(:not_found)
      %PropertyDefinition{} = definition -> apply_definition_update(definition, attrs)
    end
  end

  defp apply_definition_update(%PropertyDefinition{} = definition, attrs) do
    normalized = normalize_definition_attrs(attrs)

    with :ok <- check_type_immutable(definition, normalized),
         :ok <- check_required_gate(definition, normalized) do
      persist_definition_update(definition, normalized)
    else
      {:error, reason} -> Repo.rollback(reason)
      {:error, reason, info} -> Repo.rollback({reason, info})
    end
  end

  defp persist_definition_update(%PropertyDefinition{} = definition, normalized) do
    case definition |> PropertyDefinition.changeset(normalized) |> Repo.update() do
      {:ok, updated} -> attach_options(updated)
      {:error, changeset} -> Repo.rollback(map_conflict(changeset))
    end
  end

  defp translate_update_result({:ok, %PropertyDefinition{} = definition}), do: {:ok, definition}
  defp translate_update_result({:error, :not_found}), do: {:error, :not_found}
  defp translate_update_result({:error, :type_immutable}), do: {:error, :type_immutable}

  defp translate_update_result({:error, {:required_blocked, info}}),
    do: {:error, :required_blocked, info}

  defp translate_update_result({:error, {:conflict, changeset}}),
    do: {:error, :conflict, changeset}

  defp translate_update_result({:error, %Ecto.Changeset{} = changeset}),
    do: {:error, changeset}

  @spec retire_definition(String.t()) ::
          {:ok, definition()}
          | {:error, :not_found}
          | {:error, :still_referenced, %{active_value_count: non_neg_integer()}}
  def retire_definition(id) when is_binary(id) do
    Repo.transaction(fn -> locked_retire_definition(id) end)
    |> translate_retire_result()
  end

  defp locked_retire_definition(id) do
    case Repo.get(PropertyDefinition, id, lock: "FOR UPDATE") do
      nil ->
        Repo.rollback(:not_found)

      %PropertyDefinition{retired_at: retired_at} = definition when not is_nil(retired_at) ->
        attach_options(definition)

      %PropertyDefinition{} = definition ->
        gate_retire_definition(definition)
    end
  end

  defp gate_retire_definition(%PropertyDefinition{} = definition) do
    count = active_value_count(definition.id)

    if count > 0 do
      Repo.rollback({:still_referenced, %{active_value_count: count}})
    else
      stamp_retire_definition(definition)
    end
  end

  defp stamp_retire_definition(%PropertyDefinition{} = definition) do
    definition
    |> Ecto.Changeset.change(%{retired_at: DateTime.utc_now()})
    |> Repo.update!()
    |> attach_options()
  end

  defp translate_retire_result({:ok, %PropertyDefinition{} = definition}), do: {:ok, definition}
  defp translate_retire_result({:error, :not_found}), do: {:error, :not_found}

  defp translate_retire_result({:error, {:still_referenced, info}}),
    do: {:error, :still_referenced, info}

  # ── Options: reads ──────────────────────────────────────────────

  @spec list_options(String.t()) :: [option()]
  def list_options(definition_id) when is_binary(definition_id) do
    from(o in PropertyOption,
      where: o.property_definition_id == ^definition_id,
      order_by: [asc: o.position, asc: o.label]
    )
    |> Repo.all()
  end

  @spec get_option(String.t()) :: {:ok, option()} | {:error, :not_found}
  def get_option(id) when is_binary(id) do
    case Repo.get(PropertyOption, id) do
      nil -> {:error, :not_found}
      %PropertyOption{} = option -> {:ok, option}
    end
  end

  # ── Options: writes ─────────────────────────────────────────────

  @spec create_option(String.t(), map()) ::
          {:ok, option()}
          | {:error, :not_found}
          | {:error, :not_single_select}
          | {:error, :conflict, Ecto.Changeset.t()}
          | {:error, Ecto.Changeset.t()}
  def create_option(definition_id, attrs)
      when is_binary(definition_id) and is_map(attrs) do
    case Repo.get(PropertyDefinition, definition_id) do
      nil ->
        {:error, :not_found}

      %PropertyDefinition{value_type: value_type} when value_type != "single_select" ->
        {:error, :not_single_select}

      %PropertyDefinition{id: id} ->
        normalized =
          normalize_option_attrs(attrs)
          |> Map.put("property_definition_id", id)

        %PropertyOption{}
        |> PropertyOption.changeset(normalized)
        |> Repo.insert()
        |> handle_option_result()
    end
  end

  @spec update_option(String.t(), map()) ::
          {:ok, option()}
          | {:error, :not_found}
          | {:error, :conflict, Ecto.Changeset.t()}
          | {:error, Ecto.Changeset.t()}
  def update_option(id, attrs) when is_binary(id) and is_map(attrs) do
    case Repo.get(PropertyOption, id) do
      nil ->
        {:error, :not_found}

      %PropertyOption{} = option ->
        option
        |> PropertyOption.changeset(normalize_option_attrs(attrs))
        |> Repo.update()
        |> handle_option_result()
    end
  end

  @spec retire_option(String.t()) ::
          {:ok, option()}
          | {:error, :not_found}
          | {:error, :still_referenced, %{active_value_count: non_neg_integer()}}
  def retire_option(id) when is_binary(id) do
    Repo.transaction(fn -> locked_retire_option(id) end)
    |> translate_option_retire_result()
  end

  defp locked_retire_option(id) do
    case Repo.get(PropertyOption, id, lock: "FOR UPDATE") do
      nil -> Repo.rollback(:not_found)
      %PropertyOption{retired_at: retired_at} = option when not is_nil(retired_at) -> option
      %PropertyOption{} = option -> gate_retire_option(option)
    end
  end

  defp gate_retire_option(%PropertyOption{} = option) do
    count = active_option_value_count(option.id)

    if count > 0 do
      Repo.rollback({:still_referenced, %{active_value_count: count}})
    else
      stamp_retire_option(option)
    end
  end

  defp stamp_retire_option(%PropertyOption{} = option) do
    option
    |> Ecto.Changeset.change(%{retired_at: DateTime.utc_now()})
    |> Repo.update!()
  end

  defp translate_option_retire_result({:ok, %PropertyOption{} = option}), do: {:ok, option}
  defp translate_option_retire_result({:error, :not_found}), do: {:error, :not_found}

  defp translate_option_retire_result({:error, {:still_referenced, info}}),
    do: {:error, :still_referenced, info}

  # ── Gates ───────────────────────────────────────────────────────

  defp check_type_immutable(%PropertyDefinition{} = definition, normalized) do
    case Map.fetch(normalized, "value_type") do
      {:ok, next} when next != definition.value_type ->
        if definition_used?(definition.id) do
          {:error, :type_immutable}
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  defp check_required_gate(%PropertyDefinition{} = definition, normalized) do
    case Map.fetch(normalized, "required") do
      {:ok, true} when definition.required != true ->
        effective = %{definition | required: true}

        case invalid_item_ids_for_required(effective) do
          [] -> :ok
          ids -> {:error, :required_blocked, %{item_ids: ids}}
        end

      _ ->
        :ok
    end
  end

  defp definition_used?(definition_id) do
    values? =
      from(v in ItemPropertyValue, where: v.property_definition_id == ^definition_id)
      |> Repo.exists?()

    options? =
      from(o in PropertyOption, where: o.property_definition_id == ^definition_id)
      |> Repo.exists?()

    values? or options?
  end

  defp active_value_count(definition_id) do
    from(v in ItemPropertyValue,
      join: i in "inventory_items",
      on: i.id == v.item_id,
      where: v.property_definition_id == ^definition_id,
      where: is_nil(i.archived_at),
      select: count(v.item_id)
    )
    |> Repo.one() || 0
  end

  defp active_option_value_count(option_id) do
    from(v in ItemPropertyValue,
      join: i in "inventory_items",
      on: i.id == v.item_id,
      where: v.option_id == ^option_id,
      where: is_nil(i.archived_at),
      select: count(v.item_id)
    )
    |> Repo.one() || 0
  end

  defp invalid_item_ids_for_required(%PropertyDefinition{} = definition) do
    active_item_ids = active_item_ids_for_category(definition.category_id)

    if active_item_ids == [] do
      []
    else
      values_by_item = values_by_item_for_definition(definition.id, active_item_ids)
      live_option_ids = live_option_ids_for_definition(definition)

      Enum.reject(active_item_ids, fn item_id ->
        valid_value?(
          definition,
          Map.get(values_by_item, item_id),
          live_option_ids
        )
      end)
    end
  end

  defp active_item_ids_for_category(category_id) do
    from(i in "inventory_items",
      where: i.category_id == type(^category_id, :binary_id),
      where: is_nil(i.archived_at),
      select: fragment("?::text", i.id)
    )
    |> Repo.all()
  end

  defp values_by_item_for_definition(definition_id, item_ids) do
    from(v in ItemPropertyValue,
      where: v.property_definition_id == ^definition_id,
      where: v.item_id in ^item_ids,
      select: {fragment("?::text", v.item_id), v}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp live_option_ids_for_definition(%PropertyDefinition{id: id, value_type: "single_select"}) do
    from(o in PropertyOption,
      where: o.property_definition_id == ^id,
      where: is_nil(o.retired_at),
      select: fragment("?::text", o.id)
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp live_option_ids_for_definition(%PropertyDefinition{}), do: MapSet.new()

  defp valid_value?(
         %PropertyDefinition{value_type: "text"},
         %ItemPropertyValue{
           text_value: text
         },
         _live
       )
       when is_binary(text) do
    String.trim(text) != ""
  end

  defp valid_value?(%PropertyDefinition{value_type: "text"}, _value, _live), do: false

  defp valid_value?(
         %PropertyDefinition{value_type: "decimal"},
         %ItemPropertyValue{
           decimal_value: decimal
         },
         _live
       )
       when not is_nil(decimal),
       do: true

  defp valid_value?(%PropertyDefinition{value_type: "decimal"}, _value, _live), do: false

  defp valid_value?(
         %PropertyDefinition{value_type: "boolean"},
         %ItemPropertyValue{
           boolean_value: boolean
         },
         _live
       )
       when is_boolean(boolean),
       do: true

  defp valid_value?(%PropertyDefinition{value_type: "boolean"}, _value, _live), do: false

  defp valid_value?(
         %PropertyDefinition{value_type: "single_select"},
         %ItemPropertyValue{option_id: option_id},
         live
       )
       when not is_nil(option_id) do
    MapSet.member?(live, option_id)
  end

  defp valid_value?(%PropertyDefinition{value_type: "single_select"}, _value, _live), do: false

  # ── Reads helpers ───────────────────────────────────────────────

  defp attach_options(%PropertyDefinition{} = definition) do
    %PropertyDefinition{definition | options: list_options(definition.id)}
  end

  defp sort_definitions(definitions) do
    Enum.sort_by(definitions, fn %PropertyDefinition{identifying_position: pos, label: label} ->
      {if(is_nil(pos), do: 1, else: 0), pos || 0, String.downcase(label || "")}
    end)
  end

  # ── Result helpers ──────────────────────────────────────────────

  defp handle_definition_result({:ok, %PropertyDefinition{} = definition}) do
    {:ok, attach_options(definition)}
  end

  defp handle_definition_result({:error, %Ecto.Changeset{} = changeset}) do
    if conflict?(changeset, [:label, :identifying_position]),
      do: {:error, :conflict, changeset},
      else: {:error, changeset}
  end

  defp handle_option_result({:ok, %PropertyOption{} = option}), do: {:ok, option}

  defp handle_option_result({:error, %Ecto.Changeset{} = changeset}) do
    if conflict?(changeset, [:label]),
      do: {:error, :conflict, changeset},
      else: {:error, changeset}
  end

  defp map_conflict(%Ecto.Changeset{} = changeset) do
    if conflict?(changeset, [:label, :identifying_position]),
      do: {:conflict, changeset},
      else: changeset
  end

  defp conflict?(%Ecto.Changeset{errors: errors}, fields) do
    Enum.any?(errors, fn
      {field, {"has already been taken", _}} -> field in fields
      _ -> false
    end)
  end

  # ── Attr normalization ──────────────────────────────────────────

  defp normalize_definition_attrs(attrs) when is_map(attrs) do
    %{
      "label" => take_first(attrs, ["label", :label]),
      "value_type" => take_first(attrs, ["valueType", "value_type", :valueType, :value_type]),
      "required" => take_first(attrs, ["required", :required]),
      "identifying_position" =>
        take_first(attrs, [
          "identifyingPosition",
          "identifying_position",
          :identifyingPosition,
          :identifying_position
        ])
    }
    |> normalize_identifying_position()
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp normalize_identifying_position(map) do
    case Map.get(map, "identifying_position") do
      nil -> map
      "" -> Map.put(map, "identifying_position", nil)
      value -> Map.put(map, "identifying_position", value)
    end
  end

  defp normalize_option_attrs(attrs) when is_map(attrs) do
    %{
      "label" => take_first(attrs, ["label", :label]),
      "position" => take_first(attrs, ["position", :position])
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp take_first(attrs, keys) do
    Enum.find_value(keys, nil, fn key ->
      case Map.fetch(attrs, key) do
        {:ok, value} -> {:ok, value}
        :error -> nil
      end
    end)
    |> case do
      {:ok, value} -> value
      nil -> nil
    end
  end
end
