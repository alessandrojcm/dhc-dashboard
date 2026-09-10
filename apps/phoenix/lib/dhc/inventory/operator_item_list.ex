defmodule Dhc.Inventory.OperatorItemList do
  @moduledoc """
  ALE-284c: the paginated operator item read behind `Dhc.Inventory`.

  Where `Dhc.Inventory.OperatorItems` resolves one item and
  `Dhc.Inventory.OperatorItemLifecycle` changes availability, this slice
  answers "which items are there?" for the operator viewer contract:

    * **Stable ordering.** Rows order by the immutable slug with an `id`
      tie-break, so a page boundary cannot shift under concurrent edits.
      The slug is the item's identity, which makes it the only ordering key
      that no command can change (a derived label can change on every value
      edit, and `created_at` collides for bulk-created items).
    * **Exact counts.** `total_count` is an exact `COUNT(*)` over the same
      filtered set, never an estimate (ADR 0005 / spec ALE-280).
    * **Archive is opt-in.** Archived items are absent by default and
      reachable only through the explicit `archived` filter (story 54).
    * **Filters.** Category (multi-value) and typed property values
      (`definitionId:value` pairs, OR within one definition, AND across
      definitions). Absent or empty means no filter.

  Cursors are opaque and bind to every option that changes the result set,
  so a cursor from another filter set or limit returns `:bad_cursor` rather
  than silently serving the wrong page. Rows project through
  `Dhc.Inventory.ItemProjection.project_all/1`, which batches the page's
  aggregates, so the derived label and availability cannot drift from the
  single-item read.
  """

  import Ecto.Query

  alias Dhc.CursorPagination
  alias Dhc.Inventory.Item
  alias Dhc.Inventory.ItemProjection
  alias Dhc.Inventory.ItemPropertyValue
  alias Dhc.Repo

  @allowed_limits [10, 25, 50, 100]
  @default_limit 25
  @allowed_directions ~w(asc desc)
  @allowed_archived ~w(exclude include only)

  # The slug is immutable, so it is the one ordering key no command can
  # change underneath a cursor.
  @sort_specs %{"slug" => %{field: :slug}}

  @type page :: %{
          items: [Item.t()],
          total_count: non_neg_integer(),
          limit: pos_integer(),
          next_cursor: String.t() | nil,
          previous_cursor: String.t() | nil
        }

  @type error ::
          :invalid_limit
          | :invalid_direction
          | :invalid_archived
          | :invalid_category
          | :invalid_property
          | :bad_cursor

  @doc """
  List operator items as a cursor-paginated page with an exact total count.
  """
  @spec list_operator_items(map()) :: {:ok, page()} | {:error, error()}
  def list_operator_items(params \\ %{}) when is_map(params) or is_list(params) do
    with {:ok, opts} <- parse_options(params),
         {:ok, cursor} <- CursorPagination.parse_cursor(opts, &cursor_context/1) do
      {:ok, build_page(opts, cursor)}
    end
  end

  defp build_page(opts, cursor) do
    rows =
      opts
      |> base_query()
      |> CursorPagination.apply_cursor(cursor, opts, @sort_specs)
      |> CursorPagination.apply_order(:slug, CursorPagination.query_direction(opts, cursor))
      |> limit(^(opts.limit + 1))
      |> Repo.all()
      |> CursorPagination.maybe_reverse(cursor)

    page = CursorPagination.page(rows, opts, cursor, &cursor_context/1, &cursor_value/2)

    %{
      items: ItemProjection.project_all(page.visible_rows),
      total_count: total_count(opts),
      limit: opts.limit,
      next_cursor: page.next_cursor,
      previous_cursor: page.previous_cursor
    }
  end

  defp total_count(opts) do
    opts |> base_query() |> exclude(:order_by) |> select([i], count(i.id)) |> Repo.one()
  end

  # ── Query ───────────────────────────────────────────────────────

  # Target reads only ever see slugged rows: legacy create paths leave the
  # slug null until ALE-289 removes them, and an unslugged row has no
  # identity this viewer can resolve or page by.
  defp base_query(opts) do
    from(i in Item, as: :item, where: not is_nil(i.slug))
    |> filter_archived(opts.archived)
    |> filter_categories(opts.category_ids)
    |> filter_properties(opts.properties)
  end

  defp filter_archived(query, "exclude"), do: where(query, [i], is_nil(i.archived_at))
  defp filter_archived(query, "only"), do: where(query, [i], not is_nil(i.archived_at))
  defp filter_archived(query, "include"), do: query

  defp filter_categories(query, []), do: query

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
  # and the operator filtering by "Large" should not have to know which
  # column stores it. Text compares case-insensitively like the search does.
  defp property_value_match(values) do
    Enum.reduce(values, dynamic(false), fn value, acc ->
      dynamic(
        [v],
        ^acc or
          fragment("?::text = ?", v.option_id, ^value) or
          fragment("lower(?) = lower(?)", v.text_value, ^value) or
          fragment("?::text = ?", v.boolean_value, ^value) or
          fragment("?::text = ?", v.decimal_value, ^value)
      )
    end)
  end

  # ── Options ─────────────────────────────────────────────────────

  defp parse_options(params) when is_list(params), do: parse_options(Map.new(params))

  defp parse_options(params) do
    with {:ok, limit} <- parse_limit(take(params, ["limit"])),
         {:ok, direction} <- parse_direction(take(params, ["direction"])),
         {:ok, archived} <- parse_archived(take(params, ["archived"])),
         {:ok, category_ids} <- parse_categories(take(params, ["categoryId", "category_id"])),
         {:ok, properties} <- parse_properties(take(params, ["property", "properties"])) do
      {:ok,
       %{
         limit: limit,
         sort: "slug",
         direction: direction,
         archived: archived,
         category_ids: category_ids,
         properties: properties,
         cursor: blank_to_nil(take(params, ["cursor"]))
       }}
    end
  end

  defp parse_limit(nil), do: {:ok, @default_limit}
  defp parse_limit(""), do: {:ok, @default_limit}
  defp parse_limit(limit) when limit in @allowed_limits, do: {:ok, limit}

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, ""} -> parse_limit(parsed)
      _other -> {:error, :invalid_limit}
    end
  end

  defp parse_limit(_limit), do: {:error, :invalid_limit}

  defp parse_direction(nil), do: {:ok, "asc"}
  defp parse_direction(""), do: {:ok, "asc"}

  defp parse_direction(direction) when is_binary(direction) do
    if direction in @allowed_directions,
      do: {:ok, direction},
      else: {:error, :invalid_direction}
  end

  defp parse_direction(_direction), do: {:error, :invalid_direction}

  defp parse_archived(nil), do: {:ok, "exclude"}
  defp parse_archived(""), do: {:ok, "exclude"}

  defp parse_archived(archived) when is_binary(archived) do
    if archived in @allowed_archived,
      do: {:ok, archived},
      else: {:error, :invalid_archived}
  end

  defp parse_archived(_archived), do: {:error, :invalid_archived}

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
  end

  defp parse_properties(_raw), do: {:error, :invalid_property}

  defp accumulate_property(acc, definition_id, value) do
    case Ecto.UUID.cast(definition_id) do
      {:ok, id} -> {:cont, {:ok, Map.update(acc, id, [value], &(&1 ++ [value]))}}
      :error -> {:halt, {:error, :invalid_property}}
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

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # Everything that changes the result set is bound into the cursor, so a
  # cursor cannot be replayed against a different query.
  defp cursor_context(opts) do
    %{
      "limit" => opts.limit,
      "sort" => opts.sort,
      "direction" => opts.direction,
      "archived" => opts.archived,
      "categoryIds" => Enum.sort(opts.category_ids),
      "properties" =>
        opts.properties |> Enum.sort() |> Enum.map(fn {k, v} -> [k, Enum.sort(v)] end)
    }
  end

  defp cursor_value(row, _opts), do: row.slug
end
