defmodule Dhc.Inventory.MemberCatalog do
  @moduledoc """
  ALE-285: the member-facing catalog read behind `Dhc.Inventory`.

  This is **not** a role variant of the operator item viewer
  (`Dhc.Inventory.OperatorItemList`): it is a different read model, and the
  difference is the point. Spec ALE-280 story 45 forbids showing members the
  container location, operator notes, or operator maintenance facts in
  ordinary browsing, and never lets availability disclose who holds an item.

  So the catalog returns its own plain maps rather than `Dhc.Inventory.Item`
  structs. A member row can only ever carry what is built here — label,
  slug, category, typed values, and a generic availability reason — so no
  future field added to the item schema or its projection can leak into a
  member response by default. Removing a field from a shared struct is a
  privacy fix you have to remember; not having the field is one you cannot
  forget.

  What members get:

    * **Non-archived items only.** There is no archive filter: retirement is
      an operator concern (story 54). A member's *own* retained loan history
      keeps showing archived items through its snapshots, which is
      `Dhc.Inventory.MemberLoans`, not this read.
    * **Search** over the derived label, the immutable slug, the category
      name, and property values. The label is derived, never stored, so it
      is searched through its ingredients — the category name and the
      identifying values it is built from.
    * **Category and property filters**, matching the operator semantics: OR
      within one definition, AND across definitions. Container is
      deliberately not a member filter (ALE-276).
    * **A generic availability reason.** `available`, `on_loan`, or
      `maintenance` and nothing else: no borrower, no dates, no maintenance
      reason or note. Availability itself is recomputed by
      `Dhc.Inventory.ItemProjection`, so the member view can never disagree
      with the operator view about whether an item is free.

  Ordering is by the immutable slug with an `id` tie-break, for the same
  reason as the operator list: it is the one key no command can change, so a
  page boundary cannot shift under concurrent edits. Cursors are opaque and
  bind to every option that changes the result set.
  """

  import Ecto.Query

  alias Dhc.CursorPagination
  alias Dhc.Inventory.EquipmentCategory
  alias Dhc.Inventory.Item
  alias Dhc.Inventory.ItemGuards
  alias Dhc.Inventory.ItemProjection
  alias Dhc.Inventory.ItemPropertyValue
  alias Dhc.Inventory.ItemValues
  alias Dhc.Inventory.PropertyDefinition
  alias Dhc.Inventory.PropertyOption
  alias Dhc.Repo

  @allowed_limits [10, 25, 50, 100]
  @default_limit 25
  @allowed_directions ~w(asc desc)

  @sort_specs %{"slug" => %{field: :slug}}

  @typedoc """
  One member-visible catalog row. `availability.reason` is the only
  explanation a member ever receives for an unavailable item.
  """
  @type catalog_item :: %{
          id: String.t(),
          slug: String.t(),
          label: String.t(),
          category: %{id: String.t(), name: String.t()} | nil,
          values: [ItemValues.value_view()],
          availability: %{available?: boolean(), reason: availability_reason()}
        }

  @type availability_reason :: :available | :on_loan | :maintenance

  @type page :: %{
          items: [catalog_item()],
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

  @doc """
  List the member catalog as a cursor-paginated page with an exact count.
  """
  @spec list_catalog_items(map()) :: {:ok, page()} | {:error, error()}
  def list_catalog_items(params \\ %{}) when is_map(params) or is_list(params) do
    with {:ok, opts} <- parse_options(params),
         {:ok, cursor} <- CursorPagination.parse_cursor(opts, &cursor_context/1) do
      {:ok, build_page(opts, cursor)}
    end
  end

  @doc """
  Resolve one non-archived catalog item by slug or id.

  An archived item is reported as `:not_found` rather than as a distinct
  reason: to a member it simply is not in the catalog, and saying "archived"
  would disclose an operator fact about an item they cannot see.
  """
  @spec resolve_catalog_item(String.t()) :: {:ok, catalog_item()} | {:error, :not_found}
  def resolve_catalog_item(slug_or_id) when is_binary(slug_or_id) do
    query =
      slug_or_id
      |> ItemGuards.item_query()
      |> where([i], not is_nil(i.slug))
      |> where([i], is_nil(i.archived_at))

    case Repo.one(query) do
      nil -> {:error, :not_found}
      %Item{} = item -> {:ok, item |> List.wrap() |> project_member_rows() |> List.first()}
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
      items: project_member_rows(page.visible_rows),
      total_count: total_count(opts),
      limit: opts.limit,
      next_cursor: page.next_cursor,
      previous_cursor: page.previous_cursor
    }
  end

  defp total_count(opts) do
    opts |> base_query() |> exclude(:order_by) |> select([i], count(i.id)) |> Repo.one()
  end

  # ── Member projection ───────────────────────────────────────────

  # Builds the member row from the shared projection's parts, so the derived
  # label and the availability decision stay identical to the operator read
  # while the *shape* stays member-only. Batched for the same reason
  # `ItemProjection.project_all/1` is: a page must not cost a query per row.
  defp project_member_rows([]), do: []

  defp project_member_rows(items) do
    values_by_item = ItemValues.list_values_by_item(Enum.map(items, & &1.id))
    categories = category_summaries(items)
    availabilities = ItemProjection.availability_by_item(items)

    Enum.map(items, fn %Item{} = item ->
      values = Map.get(values_by_item, item.id, [])
      category = Map.get(categories, item.category_id)

      %{
        id: item.id,
        slug: item.slug,
        label: ItemProjection.derive_label(category && category.name, item.slug, values),
        category: category,
        values: values,
        availability: member_availability(Map.fetch!(availabilities, item.id))
      }
    end)
  end

  # The operator statuses collapse onto the member vocabulary. `:archived`
  # cannot reach a member row (archived items are filtered out), and it is
  # mapped rather than left to fall through so a future status cannot
  # silently arrive in a member response as an unhandled atom.
  defp member_availability(%{available?: true, status: :available}),
    do: %{available?: true, reason: :available}

  defp member_availability(%{status: :on_loan}), do: %{available?: false, reason: :on_loan}
  defp member_availability(%{status: :maintenance}), do: unavailable_maintenance()
  defp member_availability(%{status: :archived}), do: unavailable_maintenance()

  # An archived item has no member-safe explanation of its own; the generic
  # maintenance reason is the closest non-disclosing answer (story 29).
  defp unavailable_maintenance, do: %{available?: false, reason: :maintenance}

  defp category_summaries(items) do
    ids = items |> Enum.map(& &1.category_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if ids == [] do
      %{}
    else
      from(c in EquipmentCategory, where: c.id in ^ids, select: %{id: c.id, name: c.name})
      |> Repo.all()
      |> Map.new(&{&1.id, &1})
    end
  end

  # ── Query ───────────────────────────────────────────────────────

  # Unslugged rows are legacy create paths (ALE-289 removes them) and have no
  # identity a member could resolve or page by; archived rows are out of the
  # catalog by definition.
  defp base_query(opts) do
    from(i in Item, as: :item, where: not is_nil(i.slug), where: is_nil(i.archived_at))
    |> filter_categories(opts.category_ids)
    |> filter_properties(opts.properties)
    |> apply_search(opts.q)
  end

  defp filter_categories(query, []), do: query

  defp filter_categories(query, category_ids),
    do: where(query, [i], i.category_id in ^category_ids)

  # One `EXISTS` per definition ANDs the definitions together while the
  # values of a single definition OR inside it — an item holds at most one
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

  # Search covers the derived label by searching what it is derived from.
  # There is no stored label and no `search_text` column to feed
  # `websearch_to_tsquery` (the ADR 0005 convention), so this is a
  # case-insensitive substring match over the slug, the category name, and
  # the property values — which together are exactly the label's ingredients.
  defp apply_search(query, nil), do: query

  defp apply_search(query, q) do
    pattern = "%" <> escape_like(q) <> "%"

    where(
      query,
      [i],
      ilike(i.slug, ^pattern) or
        exists(
          from(c in EquipmentCategory,
            where: c.id == parent_as(:item).category_id,
            where: ilike(c.name, ^pattern),
            select: 1
          )
        ) or
        exists(
          from(v in ItemPropertyValue,
            join: d in PropertyDefinition,
            on: d.id == v.property_definition_id,
            left_join: o in PropertyOption,
            on: o.id == v.option_id,
            where: v.item_id == parent_as(:item).id,
            where:
              ilike(v.text_value, ^pattern) or ilike(o.label, ^pattern) or
                ilike(fragment("?::text", v.decimal_value), ^pattern),
            select: 1
          )
        )
    )
  end

  # A member typing `50%` must search for that literal text rather than for
  # "anything", so LIKE metacharacters are escaped before interpolation.
  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  # ── Options ─────────────────────────────────────────────────────

  defp parse_options(params) when is_list(params), do: parse_options(Map.new(params))

  defp parse_options(params) do
    with {:ok, limit} <- parse_limit(take(params, ["limit"])),
         {:ok, direction} <- parse_direction(take(params, ["direction"])),
         {:ok, category_ids} <- parse_categories(take(params, ["categoryId", "category_id"])),
         {:ok, properties} <- parse_properties(take(params, ["property", "properties"])) do
      {:ok,
       %{
         limit: limit,
         sort: "slug",
         direction: direction,
         category_ids: category_ids,
         properties: properties,
         q: blank_to_nil(take(params, ["q"])),
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

  # Category ids bind to a UUID column, so a malformed entry fails here as a
  # domain error; reaching the query would raise out of the API's error
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

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(_value), do: nil

  # Everything that changes the result set is bound into the cursor, so a
  # cursor cannot be replayed against a different query.
  defp cursor_context(opts) do
    %{
      "limit" => opts.limit,
      "sort" => opts.sort,
      "direction" => opts.direction,
      "categoryIds" => Enum.sort(opts.category_ids),
      "properties" =>
        opts.properties |> Enum.sort() |> Enum.map(fn {k, v} -> [k, Enum.sort(v)] end),
      "q" => opts.q
    }
  end

  defp cursor_value(row, _opts), do: row.slug
end
