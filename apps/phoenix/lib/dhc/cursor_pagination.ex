defmodule Dhc.CursorPagination do
  @moduledoc """
  Cursor pagination mechanics shared by Phoenix context list queries.

  Domain contexts keep their own option parsing, filtering, and DTO-shaped
  queries. This module owns the reusable cursor implementation: decoding,
  query direction, stable id tie-break comparisons, ordering, row slicing, and
  next/previous cursor encoding.
  """

  import Ecto.Query

  @allowed_page_directions ~w(next previous)

  @type opts :: map()
  @type cursor :: map() | nil
  @type sort_spec :: %{
          required(:field) => atom(),
          optional(:type) => atom(),
          optional(:encode) => (term() -> term()),
          optional(:decode) => (term() -> term())
        }

  @spec parse_cursor(opts(), (opts() -> map())) :: {:ok, cursor()} | {:error, :bad_cursor}
  def parse_cursor(%{cursor: nil}, _cursor_context), do: {:ok, nil}

  def parse_cursor(opts, cursor_context) when is_function(cursor_context, 1) do
    with cursor when is_binary(cursor) <- opts.cursor,
         {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, decoded} <- Jason.decode(json),
         true <- cursor_matches?(decoded, opts, cursor_context),
         true <- decoded["pageDirection"] in @allowed_page_directions,
         true <- is_binary(decoded["id"]),
         true <- Map.has_key?(decoded, "value") do
      {:ok, decoded}
    else
      _ -> {:error, :bad_cursor}
    end
  end

  @spec query_direction(opts(), cursor()) :: String.t()
  def query_direction(opts, %{"pageDirection" => "previous"}), do: flip(opts.direction)
  def query_direction(opts, _cursor), do: opts.direction

  @spec apply_cursor(Ecto.Queryable.t(), cursor(), opts(), %{String.t() => sort_spec()}) ::
          Ecto.Query.t()
  def apply_cursor(query, nil, _opts, _sort_specs), do: query

  def apply_cursor(query, cursor, opts, sort_specs) do
    spec = Map.fetch!(sort_specs, opts.sort)
    op = comparator(opts.direction, query_direction(opts, cursor))
    id = cursor["id"]
    value = cursor_value_for_query(cursor["value"], spec)

    apply_cursor_comparison(query, spec.field, Map.get(spec, :type), op, value, id)
  end

  @spec apply_order(Ecto.Queryable.t(), atom(), String.t()) :: Ecto.Query.t()
  def apply_order(query, field_name, "asc") do
    order_by(query, [e], asc: field(e, ^field_name), asc: e.id)
  end

  def apply_order(query, field_name, "desc") do
    order_by(query, [e], desc: field(e, ^field_name), desc: e.id)
  end

  @spec page([term()], opts(), cursor(), (opts() -> map()), (term(), opts() -> term())) :: map()
  def page(rows, opts, cursor, cursor_context, cursor_value) do
    visible_rows = Enum.take(rows, opts.limit)

    %{
      visible_rows: visible_rows,
      next_cursor: next_cursor(visible_rows, rows, opts, cursor, cursor_context, cursor_value),
      previous_cursor:
        previous_cursor(visible_rows, rows, opts, cursor, cursor_context, cursor_value)
    }
  end

  @spec forward_page([term()], opts(), (opts() -> map()), (term(), opts() -> term())) :: map()
  def forward_page(rows, opts, cursor_context, cursor_value) do
    visible_rows = Enum.take(rows, opts.limit)

    %{
      visible_rows: visible_rows,
      next_cursor:
        if(length(rows) > opts.limit,
          do:
            visible_rows
            |> List.last()
            |> encode_cursor(opts, "next", cursor_context, cursor_value)
        )
    }
  end

  @spec maybe_reverse([term()], cursor()) :: [term()]
  def maybe_reverse(rows, %{"pageDirection" => "previous"}), do: Enum.reverse(rows)
  def maybe_reverse(rows, _cursor), do: rows

  @spec encode_cursor(term() | nil, opts(), String.t(), (opts() -> map()), (term(), opts() ->
                                                                              term())) ::
          String.t() | nil
  def encode_cursor(nil, _opts, _page_direction, _cursor_context, _cursor_value), do: nil

  def encode_cursor(row, opts, page_direction, cursor_context, cursor_value) do
    opts
    |> cursor_context.()
    |> Map.merge(%{
      "id" => row.id,
      "value" => cursor_value.(row, opts),
      "pageDirection" => page_direction
    })
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp cursor_matches?(cursor, opts, cursor_context) do
    Enum.all?(cursor_context.(opts), fn {key, value} -> cursor[key] == value end)
  end

  defp apply_cursor_comparison(query, field_name, nil, :after, value, id) do
    where(
      query,
      [e],
      field(e, ^field_name) > ^value or (field(e, ^field_name) == ^value and e.id > ^id)
    )
  end

  defp apply_cursor_comparison(query, field_name, nil, :before, value, id) do
    where(
      query,
      [e],
      field(e, ^field_name) < ^value or (field(e, ^field_name) == ^value and e.id < ^id)
    )
  end

  defp apply_cursor_comparison(query, field_name, type, :after, value, id) do
    where(
      query,
      [e],
      field(e, ^field_name) > type(^value, ^type) or
        (field(e, ^field_name) == type(^value, ^type) and e.id > ^id)
    )
  end

  defp apply_cursor_comparison(query, field_name, type, :before, value, id) do
    where(
      query,
      [e],
      field(e, ^field_name) < type(^value, ^type) or
        (field(e, ^field_name) == type(^value, ^type) and e.id < ^id)
    )
  end

  defp cursor_value_for_query(value, %{decode: decode}) when is_function(decode, 1),
    do: decode.(value)

  defp cursor_value_for_query(value, _spec), do: value

  defp next_cursor([], _rows, _opts, _cursor, _cursor_context, _cursor_value), do: nil

  defp next_cursor(
         visible_rows,
         _rows,
         opts,
         %{"pageDirection" => "previous"},
         cursor_context,
         cursor_value
       ) do
    visible_rows |> List.last() |> encode_cursor(opts, "next", cursor_context, cursor_value)
  end

  defp next_cursor(visible_rows, rows, opts, _cursor, cursor_context, cursor_value) do
    if length(rows) > opts.limit,
      do: visible_rows |> List.last() |> encode_cursor(opts, "next", cursor_context, cursor_value)
  end

  defp previous_cursor([], _rows, _opts, _cursor, _cursor_context, _cursor_value), do: nil
  defp previous_cursor(_visible_rows, _rows, _opts, nil, _cursor_context, _cursor_value), do: nil

  defp previous_cursor(
         visible_rows,
         rows,
         opts,
         %{"pageDirection" => "previous"},
         cursor_context,
         cursor_value
       ) do
    if length(rows) > opts.limit,
      do:
        visible_rows
        |> List.first()
        |> encode_cursor(opts, "previous", cursor_context, cursor_value)
  end

  defp previous_cursor(visible_rows, _rows, opts, _cursor, cursor_context, cursor_value) do
    visible_rows |> List.first() |> encode_cursor(opts, "previous", cursor_context, cursor_value)
  end

  defp comparator("asc", "asc"), do: :after
  defp comparator("asc", "desc"), do: :before
  defp comparator("desc", "desc"), do: :before
  defp comparator("desc", "asc"), do: :after

  defp flip("asc"), do: "desc"
  defp flip("desc"), do: "asc"
end
