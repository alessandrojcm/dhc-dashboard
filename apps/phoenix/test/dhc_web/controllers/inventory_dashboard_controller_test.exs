defmodule DhcWeb.InventoryDashboardControllerTest do
  use DhcWeb.ConnCase, async: false

  alias Dhc.Repo

  @actor_id "11111111-1111-1111-1111-111111111111"

  defmodule Verifier do
    def verify("member-token") do
      {:ok,
       %{
         sub: "11111111-1111-1111-1111-111111111111",
         email: "member@example.com",
         roles: ["member"],
         raw: %{}
       }}
    end

    def verify(_token), do: {:error, :invalid_token}
  end

  setup do
    original = Application.get_env(:dhc, :auth_verifier)
    Application.put_env(:dhc, :auth_verifier, Verifier)

    {:ok, _} =
      Repo.query(
        "INSERT INTO auth.users (id, aud, role, email) VALUES ($1, 'authenticated', 'authenticated', $2)",
        [Ecto.UUID.dump!(@actor_id), "inventory-dashboard@example.com"]
      )

    on_exit(fn -> Application.put_env(:dhc, :auth_verifier, original) end)

    :ok
  end

  test "returns inventory dashboard counts for an authenticated member", %{conn: conn} do
    conn = auth_conn(conn) |> get("/api/inventory/stats")

    assert %{
             "data" => %{
               "categories" => initial_categories,
               "containers" => initial_containers,
               "items" => initial_items,
               "maintenance" => initial_maintenance
             }
           } = json_response(conn, 200)

    {:ok, category} = Dhc.Inventory.create_category(%{"name" => "Dashboard stats"})
    {:ok, container} = Dhc.Inventory.create_container(%{"name" => "Stats box"}, @actor_id)

    {:ok, _item} =
      Dhc.Inventory.create_item(
        %{
          "categoryId" => category.id,
          "containerId" => container.id,
          "quantity" => 1,
          "outForMaintenance" => true
        },
        @actor_id
      )

    conn = build_conn() |> auth_conn() |> get("/api/inventory/stats")

    assert %{
             "data" => %{
               "categories" => categories,
               "containers" => containers,
               "items" => items,
               "maintenance" => maintenance
             }
           } = json_response(conn, 200)

    assert categories == initial_categories + 1
    assert containers == initial_containers + 1
    assert items == initial_items + 1
    assert maintenance == initial_maintenance + 1
  end

  test "requires authentication", %{conn: conn} do
    conn = get(conn, "/api/inventory/stats")
    assert json_response(conn, 401)
  end

  defp auth_conn(conn) do
    put_req_header(conn, "authorization", "Bearer member-token")
  end
end
