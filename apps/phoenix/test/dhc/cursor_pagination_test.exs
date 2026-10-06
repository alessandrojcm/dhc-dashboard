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

      # Rows arrive in query order and more than `limit` exist, so the page can
      # continue forward from its last row and backward from its first.
      assert previous_page.visible_rows == [%{id: "1", name: "Ada"}, %{id: "2", name: "Grace"}]

      assert decode!(previous_page.next_cursor, opts) ==
               %{"id" => "2", "value" => "Grace", "pageDirection" => "next"}

      assert decode!(previous_page.previous_cursor, opts) ==
               %{"id" => "1", "value" => "Ada", "pageDirection" => "previous"}
    end

    test "a previous page with no earlier rows has no previous cursor" do
      opts = %{limit: 2, sort: "name", direction: "asc", cursor: nil, q: nil}
      rows = [%{id: "1", name: "Ada"}, %{id: "2", name: "Grace"}]

      page =
        CursorPagination.page(
          rows,
          opts,
          %{"pageDirection" => "previous"},
          &cursor_context/1,
          &cursor_value/2
        )

      assert page.previous_cursor == nil
      assert decode!(page.next_cursor, opts)["id"] == "2"
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

  defp decode!(cursor, opts) do
    assert {:ok, decoded} =
             CursorPagination.parse_cursor(%{opts | cursor: cursor}, &cursor_context/1)

    Map.take(decoded, ["id", "value", "pageDirection"])
  end
end
