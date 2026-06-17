defmodule DhcWeb.Plugs.CorsTest do
  use DhcWeb.ConnCase, async: true

  @origin "http://localhost:5173"

  test "answers API preflight requests before router matching", %{conn: conn} do
    conn =
      conn
      |> put_req_header("origin", @origin)
      |> put_req_header("access-control-request-method", "GET")
      |> put_req_header("access-control-request-headers", "authorization,content-type")
      |> put_req_header("access-control-request-private-network", "true")
      |> options("/api/waitlist/entries")

    assert response(conn, 204) == ""
    assert get_resp_header(conn, "access-control-allow-origin") == [@origin]
    assert get_resp_header(conn, "access-control-allow-credentials") == ["true"]

    assert get_resp_header(conn, "access-control-allow-methods") == [
             "GET, POST, PUT, PATCH, DELETE, OPTIONS"
           ]

    assert get_resp_header(conn, "access-control-allow-headers") == [
             "authorization,content-type"
           ]

    assert get_resp_header(conn, "access-control-allow-private-network") == ["true"]
  end

  test "adds CORS headers to allowed API responses", %{conn: conn} do
    conn =
      conn
      |> put_req_header("origin", @origin)
      |> get("/api/health")

    assert json_response(conn, 200)
    assert get_resp_header(conn, "access-control-allow-origin") == [@origin]
    assert get_resp_header(conn, "access-control-allow-credentials") == ["true"]
  end

  test "does not add allow-origin for disallowed origins", %{conn: conn} do
    conn =
      conn
      |> put_req_header("origin", "https://evil.example.com")
      |> options("/api/waitlist/entries")

    assert response(conn, 204) == ""
    assert get_resp_header(conn, "access-control-allow-origin") == []
  end
end
