defmodule DhcWeb.ConditionalRequestsTest do
  use ExUnit.Case, async: true

  import Plug.Conn

  alias DhcWeb.ConditionalRequests

  describe "write_options/1" do
    test "keeps writes unconditional when no header is present" do
      assert {:ok, []} = ConditionalRequests.write_options(conn())
    end

    test "converts a strong version tag into context options" do
      conn = put_req_header(conn(), "if-match", ~s("7"))

      assert {:ok, [expected_lock_version: 7]} = ConditionalRequests.write_options(conn)
    end

    test "converts the wildcard into an existing-entity context option" do
      conn = put_req_header(conn(), "if-match", "*")

      assert {:ok, [expected_lock_version: :*]} = ConditionalRequests.write_options(conn)
    end

    test "retains malformed If-Match semantics" do
      conn = put_req_header(conn(), "if-match", "7")

      assert {:error, :invalid_if_match} = ConditionalRequests.write_options(conn)
    end

    test "retains unsupported date-based conditional semantics" do
      for header <- ~w(if-modified-since if-unmodified-since if-range) do
        conn = put_req_header(conn(), header, "Mon, 31 Aug 2026 00:00:00 GMT")

        assert {:error, :unsupported_header} = ConditionalRequests.write_options(conn)
      end
    end
  end

  defp conn, do: Plug.Test.conn(:patch, "/")
end
