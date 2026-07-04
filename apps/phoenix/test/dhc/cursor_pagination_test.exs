defmodule Dhc.CursorPaginationTest do
  use ExUnit.Case, async: true

  alias Dhc.CursorPagination

  describe "page/5" do
    test "builds next cursor when more rows exist" do
      opts = %{limit: 2, sort: "name", direction: "asc", cursor: nil, q: nil}
      rows = [%{id: "1", name: "Ada"}, %{id: "2", name: "Grace"}, %{id: "3", name: "Mary"}]

      page = CursorPagination.page(rows, opts, nil, &cursor_context/1, &cursor_value/2)

      assert page.visible_rows == [%{id: "1", name: "Ada"}, %{id: "2", name: "Grace"}]
      assert is_binary(page.next_cursor)
      assert is_nil(page.previous_cursor)

      assert {:ok, cursor} =
               CursorPagination.parse_cursor(
                 %{opts | cursor: page.next_cursor},
                 &cursor_context/1
               )

      assert cursor["id"] == "2"
      assert cursor["value"] == "Grace"
      assert cursor["pageDirection"] == "next"
    end

    test "builds both cursors for previous pages" do
      opts = %{limit: 2, sort: "name", direction: "asc", cursor: nil, q: nil}
      rows = [%{id: "1", name: "Ada"}, %{id: "2", name: "Grace"}, %{id: "3", name: "Mary"}]
      page = CursorPagination.page(rows, opts, nil, &cursor_context/1, &cursor_value/2)

      previous_cursor =
        CursorPagination.encode_cursor(
          %{id: "3", name: "Mary"},
          opts,
          "previous",
          &cursor_context/1,
          &cursor_value/2
        )

      previous_page =
        CursorPagination.page(
          rows,
          %{opts | cursor: previous_cursor},
          %{"pageDirection" => "previous"},
          &cursor_context/1,
          &cursor_value/2
        )

      assert is_binary(previous_page.next_cursor)
      assert is_binary(previous_page.previous_cursor)
    end
  end

  describe "parse_cursor/2" do
    test "rejects cursors from different query semantics" do
      opts = %{limit: 2, sort: "name", direction: "asc", cursor: nil, q: nil}

      cursor =
        CursorPagination.encode_cursor(
          %{id: "1", name: "Ada"},
          opts,
          "next",
          &cursor_context/1,
          &cursor_value/2
        )

      assert {:error, :bad_cursor} =
               CursorPagination.parse_cursor(
                 %{opts | limit: 10, cursor: cursor},
                 &cursor_context/1
               )
    end
  end

  defp cursor_context(opts) do
    %{"limit" => opts.limit, "sort" => opts.sort, "direction" => opts.direction, "q" => opts.q}
  end

  defp cursor_value(row, _opts), do: row.name
end
