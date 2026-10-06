defmodule DhcWeb.HealthControllerTest do
  use DhcWeb.ConnCase, async: true

  describe "index" do
    test "returns 200 GET /health", %{conn: conn} do
      conn = get(conn, "/api/health")
      assert json_response(conn, 200) == %{"data" => %{"status" => "ok"}}
    end
  end
end
