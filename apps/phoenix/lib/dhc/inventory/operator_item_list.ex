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
    * **Search.** Case-insensitive text search over the immutable slug,
      derived-label ingredients, Container name, and operator notes.
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
  alias Dhc.Inventory.PageParams
  alias Dhc.Inventory.PropertyDefinition
  alias Dhc.Repo

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

  # Slugs are immutable and unique, so they are the page key.
  defp base_query(opts) do
    from(i in Item, as: :item)
    |> filter_archived(opts.archived)
    |> filter_categories(opts.category_ids)
    |> filter_properties(opts.properties)
    |> apply_search(opts.q)
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
  # Decimals compare numerically so a stored `1.0` matches a filter of `1`.
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

  # Correlated per-row expression; promote to an indexed generated
  # column if list/count profiling shows this slowing the page.
  defp apply_search(query, nil), do: query

  defp apply_search(query, q) do
    case search_parts(q) do
      :none -> query
      {websearch, prefix} -> constrain_search(query, websearch, prefix)
    end
  end

  defp search_parts(q) do
    tokens =
      q
      |> String.replace(~r/-+/, " ")
      |> String.split()
      |> Enum.map(&sanitize_search_token/1)
      |> Enum.reject(&(&1 == ""))

    case tokens do
      [] ->
        :none

      [only] ->
        {"", only}

      many ->
        {head, [last]} = Enum.split(many, -1)
        {Enum.join(head, " "), last}
    end
  end

  # `to_tsquery` is syntax-sensitive; only alphanumerics and dots reach
  # the prefix path. Quotes, operators, and punctuation cannot 500.
  defp sanitize_search_token(token) do
    Regex.replace(~r/[^[:alnum:].]+/u, token, "")
  end

  defp constrain_search(query, websearch, last) do
    yes = ItemProjection.render_value(%{value_type: "boolean", boolean: true})
    no = ItemProjection.render_value(%{value_type: "boolean", boolean: false})

    where(
      query,
      [i],
      fragment(
        """
        to_tsvector(
          'english',
          concat_ws(
            ' ',
            replace(?, '-', ' '),
            replace(?, '-', ' '),
            (SELECT name FROM equipment_categories WHERE id = ?),
            (
              WITH RECURSIVE ancestors AS (
                SELECT id, parent_container_id, name, 0 AS depth
                FROM containers
                WHERE id = ?
                UNION ALL
                SELECT parent.id, parent.parent_container_id, parent.name, child.depth + 1
                FROM containers parent
                JOIN ancestors child ON child.parent_container_id = parent.id
              )
              SELECT string_agg(name, ' ' ORDER BY depth DESC) FROM ancestors
            ),
            (
              SELECT string_agg(
                concat_ws(
                  ' ',
                  v.text_value,
                  o.label,
                  v.decimal_value::text,
                  CASE v.boolean_value WHEN true THEN ? WHEN false THEN ? END
                ),
                ' '
              )
              FROM inventory_item_property_values v
              LEFT JOIN inventory_property_options o ON o.id = v.option_id
              WHERE v.item_id = ?
            )
          )
        ) @@ (
          CASE
            WHEN ? = '' THEN COALESCE(
              (
                SELECT to_tsquery('english', string_agg(match[1] || ':*', ' & '))
                FROM regexp_matches(to_tsvector('english', ?)::text, '''([^'']+)''', 'g') AS match
              ),
              ''::tsquery
            )
            WHEN ? = '' THEN websearch_to_tsquery('english', ?)
            ELSE websearch_to_tsquery('english', ?) && COALESCE(
              (
                SELECT to_tsquery('english', string_agg(match[1] || ':*', ' & '))
                FROM regexp_matches(to_tsvector('english', ?)::text, '''([^'']+)''', 'g') AS match
              ),
              ''::tsquery
            )
          END
        )
        """,
        i.slug,
        i.notes,
        i.category_id,
        i.container_id,
        ^yes,
        ^no,
        i.id,
        ^websearch,
        ^last,
        ^last,
        ^websearch,
        ^websearch,
        ^last
      )
    )
  end

  # ── Options ─────────────────────────────────────────────────────

  defp parse_options(params) when is_list(params), do: parse_options(Map.new(params))

  defp parse_options(params) do
    with {:ok, limit} <- PageParams.parse_limit(take(params, ["limit"])),
         {:ok, direction} <- PageParams.parse_direction(take(params, ["direction"])),
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
         q: PageParams.blank_to_nil(take(params, ["q"])),
         cursor: PageParams.blank_to_nil(take(params, ["cursor"]))
       }}
    end
  end

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
    |> validate_decimal_properties()
  end

  defp parse_properties(_raw), do: {:error, :invalid_property}

  defp accumulate_property(acc, definition_id, value) do
    case Ecto.UUID.cast(definition_id) do
      {:ok, id} -> {:cont, {:ok, Map.update(acc, id, [value], &(&1 ++ [value]))}}
      :error -> {:halt, {:error, :invalid_property}}
    end
  end

  # A decimal definition compared as text would make `1` miss stored `1.0`.
  # A value that cannot be a decimal is a 400, like a malformed category id —
  # looking up the type first is what lets option UUIDs on other definitions
  # keep working.
  defp validate_decimal_properties({:error, reason}), do: {:error, reason}

  defp validate_decimal_properties({:ok, properties}) do
    types = definition_types(Map.keys(properties))

    Enum.reduce_while(properties, {:ok, properties}, fn {id, values}, {:ok, acc} ->
      if Map.get(types, id) == "decimal" and Enum.any?(values, &(Decimal.cast(&1) == :error)) do
        {:halt, {:error, :invalid_property}}
      else
        {:cont, {:ok, acc}}
      end
    end)
  end

  defp definition_types([]), do: %{}

  defp definition_types(ids) do
    from(d in PropertyDefinition, where: d.id in ^ids, select: {d.id, d.value_type})
    |> Repo.all()
    |> Map.new()
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

  # Everything that changes the result set is bound into the cursor, so a
  # cursor cannot be replayed against a different query.
  defp cursor_context(opts) do
    %{
      "limit" => opts.limit,
      "sort" => opts.sort,
      "direction" => opts.direction,
      "archived" => opts.archived,
      "q" => opts.q,
      "categoryIds" => Enum.sort(opts.category_ids),
      "properties" =>
        opts.properties |> Enum.sort() |> Enum.map(fn {k, v} -> [k, Enum.sort(v)] end)
    }
  end

  defp cursor_value(row, _opts), do: row.slug
end
