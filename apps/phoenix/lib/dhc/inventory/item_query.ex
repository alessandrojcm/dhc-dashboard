defmodule Dhc.Inventory.ItemQuery do
  @moduledoc """
  ALE-347: the paging and filter mechanics shared by the two Item list reads,
  `Dhc.Inventory.OperatorItemList` and `Dhc.Inventory.MemberCatalog`.

  This module owns everything the two reads must agree on, so the member
  catalog cannot drift from the operator list again (it once compared
  decimals as text):

    * **Common parameters** — `limit` and `direction` (through
      `Dhc.Inventory.PageParams`), `categoryId`, `property`
      (`definitionId:value` pairs, with decimal validation against the
      definition's type), `q`, and `cursor`.
    * **Filters** — category (multi-value) and typed property values: OR
      within one definition, AND across definitions, decimals compared
      numerically so a stored `1.0` matches a filter of `1`.
    * **The page** — slug ordering with an `id` tie-break, `limit + 1`
      look-ahead, cursors bound to every option that changes the result set,
      and an exact `COUNT(*)` over the same filtered set.

  Each read model supplies a `Dhc.Inventory.ItemQuery.ReadModel`: its one extra parameter, its
  scope over the item root, its own search, and its projection. Search stays
  with the read model on purpose — the operator search reads notes and
  Container paths that the member query must never touch — and the
  projection is what keeps a member row a closed shape. Nothing here reads a
  column beyond the Item's slug, id, category, and property values.
  """

  import Ecto.Query

  alias Dhc.CursorPagination
  alias Dhc.Inventory.Item
  alias Dhc.Inventory.ItemPropertyValue
  alias Dhc.Inventory.ItemQuery.ReadModel
  alias Dhc.Inventory.PageParams
  alias Dhc.Inventory.PropertyDefinition
  alias Dhc.Repo

  # The slug is immutable, so it is the one ordering key no command can
  # change underneath a cursor.
  @sort_specs %{"slug" => %{field: :slug}}

  @type opts :: %{
          required(:limit) => pos_integer(),
          required(:sort) => String.t(),
          required(:direction) => String.t(),
          required(:category_ids) => [Ecto.UUID.t()],
          required(:properties) => %{Ecto.UUID.t() => [String.t()]},
          required(:q) => String.t() | nil,
          required(:cursor) => String.t() | nil,
          optional(atom()) => term()
        }

  @type page :: %{
          items: [term()],
          total_count: non_neg_integer(),
          limit: pos_integer(),
          next_cursor: String.t() | nil,
          previous_cursor: String.t() | nil
        }

  @type error ::
          :invalid_limit
          | :invalid_direction
          | :invalid_category
          | :invalid_property
          | :bad_cursor
          | ReadModel.param_error()

  @doc """
  Parse `params`, then read one cursor-paginated page with an exact count.
  """
  @spec list(map() | keyword(), ReadModel.t()) :: {:ok, page()} | {:error, error()}
  def list(params, %ReadModel{} = read_model) do
    with {:ok, opts} <- parse(params, read_model.param),
         {:ok, cursor} <- CursorPagination.parse_cursor(opts, &cursor_context(&1, read_model)) do
      {:ok, build_page(opts, cursor, read_model)}
    end
  end

  # ── Options ─────────────────────────────────────────────────────

  @doc """
  Parse the common parameters plus the read model's one extra parameter.

  String and atom keys are both accepted; `category_id` and `properties` are
  accepted aliases of `categoryId` and `property`.
  """
  @spec parse(map() | keyword(), ReadModel.param()) :: {:ok, opts()} | {:error, error()}
  def parse(params, param) when is_list(params), do: parse(Map.new(params), param)

  def parse(params, {name, keys, parser}) when is_map(params) do
    with {:ok, limit} <- PageParams.parse_limit(take(params, ["limit"])),
         {:ok, direction} <- PageParams.parse_direction(take(params, ["direction"])),
         {:ok, extra} <- parser.(take(params, keys)),
         {:ok, category_ids} <- parse_categories(take(params, ["categoryId", "category_id"])),
         {:ok, properties} <- parse_properties(take(params, ["property", "properties"])) do
      {:ok,
       %{
         name => extra,
         limit: limit,
         sort: "slug",
         direction: direction,
         category_ids: category_ids,
         properties: properties,
         q: PageParams.blank_to_nil(take(params, ["q"])),
         cursor: PageParams.blank_to_nil(take(params, ["cursor"]))
       }}
    end
  end

  # Category ids bind to a UUID column, so a malformed entry has to fail here
  # as a domain error; reaching the query would raise out of the API's error
  # envelope instead of answering 400.
  defp parse_categories(nil), do: {:ok, []}
  defp parse_categories(""), do: {:ok, []}

  defp parse_categories(raw) when is_binary(raw) do
    raw |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> cast_categories()
  end

  defp parse_categories(raw) when is_list(raw), do: cast_categories(raw)
  defp parse_categories(_raw), do: {:error, :invalid_category}

  defp cast_categories(entries) do
    entries
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case Ecto.UUID.cast(entry) do
        {:ok, id} -> {:cont, {:ok, acc ++ [id]}}
        :error -> {:halt, {:error, :invalid_category}}
      end
    end)
  end

  # `definitionId:value` pairs, comma-separated. Grouping by definition is
  # what makes one definition's values OR and separate definitions AND.
  defp parse_properties(nil), do: {:ok, %{}}
  defp parse_properties(""), do: {:ok, %{}}

  defp parse_properties(raw) when is_binary(raw) do
    raw
    |> String.split(",", trim: true)
    |> Enum.reduce_while({:ok, %{}}, fn pair, {:ok, acc} ->
      case String.split(pair, ":", parts: 2) do
        [definition_id, value] -> accumulate_property(acc, String.trim(definition_id), value)
        _missing_value -> {:halt, {:error, :invalid_property}}
      end
    end)
    |> validate_decimal_properties()
  end

  defp parse_properties(_raw), do: {:error, :invalid_property}

  defp accumulate_property(acc, definition_id, value) do
    case Ecto.UUID.cast(definition_id) do
      {:ok, id} -> {:cont, {:ok, Map.update(acc, id, [value], &(&1 ++ [value]))}}
      :error -> {:halt, {:error, :invalid_property}}
    end
  end

  # A value that cannot be a decimal on a decimal definition is a 400, like a
  # malformed category id. Looking up the type first is what lets option
  # UUIDs and text on other definitions keep working.
  defp validate_decimal_properties({:error, reason}), do: {:error, reason}

  defp validate_decimal_properties({:ok, properties}) do
    types = definition_types(Map.keys(properties))

    if Enum.any?(properties, fn {id, values} ->
         Map.get(types, id) == "decimal" and Enum.any?(values, &(Decimal.cast(&1) == :error))
       end),
       do: {:error, :invalid_property},
       else: {:ok, properties}
  end

  defp definition_types([]), do: %{}

  defp definition_types(ids) do
    from(d in PropertyDefinition, where: d.id in ^ids, select: {d.id, d.value_type})
    |> Repo.all()
    |> Map.new()
  end

  defp take(params, keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(params, key) do
        {:ok, value} -> {:ok, value}
        :error -> atom_fetch(params, key)
      end
    end)
    |> case do
      {:ok, value} -> value
      nil -> nil
    end
  end

  defp atom_fetch(params, key) do
    case Map.fetch(params, String.to_existing_atom(key)) do
      {:ok, value} -> {:ok, value}
      :error -> nil
    end
  rescue
    ArgumentError -> nil
  end

  # ── Filters ─────────────────────────────────────────────────────

  @doc """
  Apply the category and property filters from parsed options to a query
  whose item binding is named `:item`.
  """
  @spec filter(Ecto.Queryable.t(), opts()) :: Ecto.Query.t()
  def filter(query, opts) do
    query
    |> filter_categories(opts.category_ids)
    |> filter_properties(opts.properties)
  end

  defp filter_categories(query, []), do: from(query)

  defp filter_categories(query, category_ids),
    do: where(query, [i], i.category_id in ^category_ids)

  # One `EXISTS` per definition ANDs the definitions together, while the
  # values of a single definition OR inside it — an item has at most one
  # value per definition, so ANDing two values of the same definition could
  # never match.
  defp filter_properties(query, properties) do
    Enum.reduce(properties, query, fn {definition_id, values}, acc ->
      where(
        acc,
        [i],
        exists(
          from(v in ItemPropertyValue,
            where: v.item_id == parent_as(:item).id,
            where: v.property_definition_id == ^definition_id,
            where: ^property_value_match(values),
            select: 1
          )
        )
      )
    end)
  end

  # A supplied value may name an option id, a boolean, a decimal, or text,
  # and filtering by "Large" should not require knowing which column stores
  # it. Text compares case-insensitively. Decimals compare numerically so a
  # stored `1.0` matches a filter of `1`.
  defp property_value_match(values) do
    Enum.reduce(values, dynamic(false), fn value, acc ->
      dynamic(
        [v],
        ^acc or
          fragment("?::text = ?", v.option_id, ^value) or
          fragment("lower(?) = lower(?)", v.text_value, ^value) or
          fragment("?::text = ?", v.boolean_value, ^value) or
          ^decimal_value_match(value)
      )
    end)
  end

  defp decimal_value_match(value) do
    case Decimal.cast(value) do
      {:ok, decimal} -> dynamic([v], v.decimal_value == ^decimal)
      :error -> dynamic(false)
    end
  end

  # ── Page ────────────────────────────────────────────────────────

  defp build_page(opts, cursor, read_model) do
    context = &cursor_context(&1, read_model)

    rows =
      opts
      |> filtered_query(read_model)
      |> CursorPagination.apply_cursor(cursor, opts, @sort_specs)
      |> CursorPagination.apply_order(:slug, CursorPagination.query_direction(opts, cursor))
      |> limit(^(opts.limit + 1))
      |> Repo.all()
      |> CursorPagination.maybe_reverse(cursor)

    page = CursorPagination.page(rows, opts, cursor, context, &cursor_value/2)

    %{
      items: read_model.project.(page.visible_rows),
      total_count: total_count(opts, read_model),
      limit: opts.limit,
      next_cursor: page.next_cursor,
      previous_cursor: page.previous_cursor
    }
  end

  defp total_count(opts, read_model) do
    opts
    |> filtered_query(read_model)
    |> select([i], count(i.id))
    |> Repo.one()
  end

  defp filtered_query(opts, read_model) do
    from(i in Item, as: :item)
    |> read_model.scope.(opts)
    |> filter(opts)
    |> search(opts.q, read_model)
  end

  defp search(query, nil, _read_model), do: query
  defp search(query, q, read_model), do: read_model.search.(query, q)

  # Everything that changes the result set is bound into the cursor, so a
  # cursor cannot be replayed against a different query.
  defp cursor_context(opts, %ReadModel{param: {name, _keys, _parser}}) do
    %{
      "limit" => opts.limit,
      "sort" => opts.sort,
      "direction" => opts.direction,
      "q" => opts.q,
      "categoryIds" => Enum.sort(opts.category_ids),
      "properties" =>
        opts.properties |> Enum.sort() |> Enum.map(fn {k, v} -> [k, Enum.sort(v)] end),
      Atom.to_string(name) => cursor_param(Map.fetch!(opts, name))
    }
  end

  defp cursor_param(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp cursor_param(value), do: value

  defp cursor_value(row, _opts), do: row.slug
end
