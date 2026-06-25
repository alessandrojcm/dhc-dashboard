defmodule DhcWeb.InventoryControllerTest do
  @moduledoc """
  Request/contract tests for the Inventory overview counts endpoint
  (issue ALE-94 / PRD #93).

  Covers the four counts (`summary.containerCount`, `summary.categoryCount`,
  `summary.itemCount`, `summary.maintenanceCount`) and the Inventory RBAC:
  `quartermaster`, `president`, and `admin` can read; a member without an
  Inventory privilege receives `403`; a missing token returns `401`.

  The underlying read-model behavior (count query mechanics) is covered by
  `Dhc.InventoryTest`. These tests assert external contract behavior only.
  """

  use DhcWeb.ConnCase, async: false

  alias Dhc.InventoryFixtures
  alias Dhc.Repo

  # The canonical Inventory management roles (mirrors
  # `Dhc.Inventory.inventory_management_roles/0` and the existing dashboard
  # Inventory gate `INVENTORY_ROLES` in `src/lib/server/roles.ts`).
  @allowed_roles ~w(quartermaster president admin)
  @rejected_roles ~w(member committee_coordinator workshop_coordinator beginners_coordinator coach treasurer)

  # In-test JWT verifier: each role gets a deterministic token. The claims
  # shape mirrors what `DhcWeb.Plugs.RequireAuth` reads (`roles`).
  defmodule Verifier do
    for role <-
          ~w(quartermaster president admin member committee_coordinator workshop_coordinator beginners_coordinator coach treasurer) do
      def verify(unquote("#{role}-token")) do
        {:ok,
         %{
           sub: Ecto.UUID.generate(),
           email: "#{unquote(role)}@example.com",
           roles: [unquote(role)],
           raw: %{}
         }}
      end
    end

    def verify("bad-token"), do: {:error, :invalid_token}
    def verify(_token), do: {:error, :invalid_token}
  end

  setup do
    original = Application.get_env(:dhc, :auth_verifier)
    Application.put_env(:dhc, :auth_verifier, Verifier)

    on_exit(fn -> Application.put_env(:dhc, :auth_verifier, original) end)
  end

  defp auth_conn(conn, role), do: put_req_header(conn, "authorization", "Bearer #{role}-token")

  # ── RBAC ─────────────────────────────────────────────────────────────

  describe "overview — RBAC" do
    test "allows quartermaster, president, and admin", %{conn: _conn} do
      for role <- @allowed_roles do
        conn =
          build_conn()
          |> auth_conn(role)
          |> get("/api/inventory/overview")

        assert %{"data" => %{"summary" => _}} = json_response(conn, 200)
      end
    end

    test "returns 401 without a bearer token", %{conn: conn} do
      conn = get(conn, "/api/inventory/overview")

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "returns 401 with an invalid bearer token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer bad-token")
        |> get("/api/inventory/overview")

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "returns 403 for members without an Inventory privilege", %{conn: _conn} do
      for role <- @rejected_roles do
        conn =
          build_conn()
          |> auth_conn(role)
          |> get("/api/inventory/overview")

        assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
      end
    end
  end

  # ── Counts ───────────────────────────────────────────────────────────

  describe "overview — counts" do
    # The baseline migration (`20260512000010_create_inventory`) seeds 7
    # default equipment categories (Masks, Gorgets, …). Clear them so count
    # assertions are deterministic and not biased by the seed state.
    setup do
      Repo.delete_all(Dhc.Inventory.EquipmentCategory)
      :ok
    end

    test "returns zero counts when the inventory is empty", %{conn: conn} do
      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/overview")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "summary" => %{
                   "containerCount" => 0,
                   "categoryCount" => 0,
                   "itemCount" => 0,
                   "maintenanceCount" => 0
                 }
               }
             }
    end

    test "returns the four counts as a camelCase summary object", %{conn: conn} do
      %{id: category_1} = InventoryFixtures.category_fixture(name: "Masks")
      %{id: category_2} = InventoryFixtures.category_fixture(name: "Gloves")

      %{id: container_1} = InventoryFixtures.container_fixture(name: "Locker A")
      %{id: container_2} = InventoryFixtures.container_fixture(name: "Locker B")
      %{id: container_3} = InventoryFixtures.container_fixture(name: "Locker C")

      # Six items total: two out for maintenance, four available.
      InventoryFixtures.item_fixture(
        container_id: container_1,
        category_id: category_1,
        out_for_maintenance: false
      )

      InventoryFixtures.item_fixture(
        container_id: container_1,
        category_id: category_1,
        out_for_maintenance: true
      )

      InventoryFixtures.item_fixture(
        container_id: container_2,
        category_id: category_2,
        out_for_maintenance: false
      )

      InventoryFixtures.item_fixture(
        container_id: container_2,
        category_id: category_1,
        out_for_maintenance: true
      )

      InventoryFixtures.item_fixture(
        container_id: container_3,
        category_id: category_2,
        out_for_maintenance: false
      )

      InventoryFixtures.item_fixture(
        container_id: container_3,
        category_id: category_2,
        out_for_maintenance: false
      )

      conn =
        conn
        |> auth_conn("admin")
        |> get("/api/inventory/overview")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "summary" => %{
                   "containerCount" => 3,
                   "categoryCount" => 2,
                   "itemCount" => 6,
                   "maintenanceCount" => 2
                 }
               }
             }
    end

    test "maintenanceCount is a subset of itemCount", %{conn: conn} do
      category = InventoryFixtures.category_fixture()
      container = InventoryFixtures.container_fixture()

      # Three items: one in maintenance, two available.
      InventoryFixtures.item_fixture(container_id: container.id, category_id: category.id)
      InventoryFixtures.item_fixture(container_id: container.id, category_id: category.id)

      InventoryFixtures.item_fixture(
        container_id: container.id,
        category_id: category.id,
        out_for_maintenance: true
      )

      conn =
        conn
        |> auth_conn("president")
        |> get("/api/inventory/overview")

      assert %{"data" => %{"summary" => summary}} = json_response(conn, 200)

      assert summary == %{
               "containerCount" => 1,
               "categoryCount" => 1,
               "itemCount" => 3,
               "maintenanceCount" => 1
             }

      # Maintenance is a subset of items, never more.
      assert summary["maintenanceCount"] <= summary["itemCount"]
    end

    test "uses the summary envelope shape and does not leak storage vocabulary", %{conn: conn} do
      InventoryFixtures.category_fixture()
      InventoryFixtures.container_fixture()

      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/overview")

      body = json_response(conn, 200)

      assert %{"data" => %{"summary" => summary}} = body

      # camelCase contract fields only.
      assert Map.has_key?(summary, "containerCount")
      assert Map.has_key?(summary, "categoryCount")
      assert Map.has_key?(summary, "itemCount")
      assert Map.has_key?(summary, "maintenanceCount")

      # Storage vocabulary must not leak into the contract.
      refute Map.has_key?(summary, "container_count")
      refute Map.has_key?(summary, "item_count")
      refute Map.has_key?(summary, "out_for_maintenance")
      refute Map.has_key?(body, "containers")
      refute Map.has_key?(body, "inventory_items")
      refute Map.has_key?(body, "equipment_categories")
    end
  end
end