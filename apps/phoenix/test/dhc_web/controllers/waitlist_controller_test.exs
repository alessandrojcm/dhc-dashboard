defmodule DhcWeb.WaitlistControllerTest do
  use DhcWeb.ConnCase, async: false

  alias Dhc.Repo

  describe "index" do
    test "returns open status", %{conn: conn} do
      set_waitlist_open(true)

      conn = get(conn, "/api/waitlist/status")

      assert %{"data" => %{"isOpen" => true}} = json_response(conn, 200)
    end

    test "returns closed status", %{conn: conn} do
      set_waitlist_open(false)

      conn = get(conn, "/api/waitlist/status")

      assert %{"data" => %{"isOpen" => false}} = json_response(conn, 200)
    end
  end

  defp set_waitlist_open(open?) do
    value = if open?, do: "true", else: "false"
    result = Repo.query!("UPDATE settings SET value = $1 WHERE key = 'waitlist_open'", [value])
    assert result.num_rows == 1
  end
end
