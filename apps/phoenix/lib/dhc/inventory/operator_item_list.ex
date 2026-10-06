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

  The common parameters, the category and property filters, and the page
  itself belong to `Dhc.Inventory.ItemQuery` (ALE-347), shared with the
  member catalog. This module supplies only the `archived` parameter, its
  scope, the operator full-text search, and the projection.
  """

  import Ecto.Query

  alias Dhc.Inventory.ContainerTree
  alias Dhc.Inventory.Item
  alias Dhc.Inventory.ItemProjection
  alias Dhc.Inventory.ItemQuery
  alias Dhc.Inventory.ItemQuery.ReadModel

  @allowed_archived ~w(exclude include only)

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
    ItemQuery.list(params, %ReadModel{
      param: {:archived, ["archived"], &parse_archived/1},
      scope: &scope/2,
      search: &apply_search/2,
      project: &ItemProjection.project_all/1
    })
  end

  # ── Query ───────────────────────────────────────────────────────

  defp scope(query, opts), do: filter_archived(query, opts.archived)

  defp filter_archived(query, "exclude"), do: where(query, [i], is_nil(i.archived_at))
  defp filter_archived(query, "only"), do: where(query, [i], not is_nil(i.archived_at))
  defp filter_archived(query, "include"), do: query

  # Correlated per-row expression; promote to an indexed generated
  # column if list/count profiling shows this slowing the page.
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
    {path_ids, path_names} = container_paths()
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
              SELECT path.name
              FROM unnest(?::uuid[], ?::text[]) AS path(container_id, name)
              WHERE path.container_id = ?
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
        type(^path_ids, {:array, Ecto.UUID}),
        ^path_names,
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

  # Every Container's root-first path, read once before the query. Club scale
  # is tens of containers, so passing them as two parallel arrays keeps the
  # hierarchy walk in `ContainerTree` instead of a CTE per searched row. The
  # ` › ` separator is punctuation to the text-search parser, so the indexed
  # words are exactly the ancestor names.
  defp container_paths do
    ContainerTree.all_ids()
    |> ContainerTree.path_names()
    |> Enum.unzip()
  end

  # ── Options ─────────────────────────────────────────────────────

  defp parse_archived(nil), do: {:ok, "exclude"}
  defp parse_archived(""), do: {:ok, "exclude"}

  defp parse_archived(archived) when is_binary(archived) do
    if archived in @allowed_archived,
      do: {:ok, archived},
      else: {:error, :invalid_archived}
  end

  defp parse_archived(_archived), do: {:error, :invalid_archived}
end
