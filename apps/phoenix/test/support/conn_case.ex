defmodule DhcWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use DhcWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint DhcWeb.Endpoint

      use DhcWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest, except: [post: 3, put: 3, patch: 3, delete: 3]
      import DhcWeb.ConnCase
    end
  end

  # The API pipeline rejects non-JSON bodies (`DhcWeb.Plugs.RequireJsonBody`),
  # but `Phoenix.ConnTest` marks a params map as `multipart/mixed`. These
  # wrappers send params maps as `application/json`, like the real clients do;
  # a test that sets its own `content-type` keeps it.
  for method <- [:post, :put, :patch, :delete] do
    @doc "Dispatches a #{method} request, sending params maps as JSON."
    defmacro unquote(method)(conn, path_or_action, params_or_body) do
      method = unquote(method)

      quote do
        Phoenix.ConnTest.dispatch(
          DhcWeb.ConnCase.put_json_content_type(unquote(conn), unquote(params_or_body)),
          @endpoint,
          unquote(method),
          unquote(path_or_action),
          unquote(params_or_body)
        )
      end
    end
  end

  @doc false
  def put_json_content_type(%Plug.Conn{} = conn, params)
      when is_map(params) or is_list(params) do
    case Plug.Conn.get_req_header(conn, "content-type") do
      [] -> Plug.Conn.put_req_header(conn, "content-type", "application/json")
      _ -> conn
    end
  end

  def put_json_content_type(conn, _params), do: conn

  setup tags do
    Dhc.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Builds a fresh connection for the test endpoint. Shortcut for
  `Phoenix.ConnTest.build_conn/0` so test bodies can write `conn()` instead
  of `build_conn()` (the convention used by the auth-session tests).
  """
  def conn, do: Phoenix.ConnTest.build_conn()
end
