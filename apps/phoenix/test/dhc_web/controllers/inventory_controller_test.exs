defmodule DhcWeb.InventoryControllerTest do
  @moduledoc """
  Request/contract tests for the Inventory read endpoints
  (issues ALE-94 / ALE-95 / ALE-98 / ALE-96 / ALE-97 / ALE-99, PRD #93).

  Covers the overview counts, the Inventory Activity feed, the Inventory
  Item filter options, the Equipment Category list, the Container list, and
  the Inventory Item list, plus the Inventory RBAC: `quartermaster`,
  `president`, and `admin` can read; a member without an Inventory
  privilege receives `403`; a missing token returns `401`.

  The underlying read-model behavior (query mechanics) is covered by
  `Dhc.InventoryTest`. These tests assert external contract behavior only.
  """

  use DhcWeb.ConnCase, async: false

  alias Dhc.Inventory.{Container, EquipmentCategory, InventoryActivity, InventoryItem}
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

  # ── Activity feed (ALE-95) ───────────────────────────────────────────

  describe "activity — RBAC" do
    test "allows quartermaster, president, and admin", %{conn: _conn} do
      for role <- @allowed_roles do
        conn =
          build_conn()
          |> auth_conn(role)
          |> get("/api/inventory/activity")

        assert %{"data" => %{"activity" => _}} = json_response(conn, 200)
      end
    end

    test "returns 401 without a bearer token", %{conn: conn} do
      conn = get(conn, "/api/inventory/activity")

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "returns 401 with an invalid bearer token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer bad-token")
        |> get("/api/inventory/activity")

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "returns 403 for members without an Inventory privilege", %{conn: _conn} do
      for role <- @rejected_roles do
        conn =
          build_conn()
          |> auth_conn(role)
          |> get("/api/inventory/activity")

        assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
      end
    end
  end

  describe "activity — feed" do
    setup :seed_activity_fixture

    test "returns newest-first activity ordered by createdAt desc, id desc", %{
      conn: conn,
      activity: activity
    } do
      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/activity")

      assert %{
               "data" => %{
                 "activity" => [first | _rest],
                 "limit" => 10,
                 "nextCursor" => nil
               }
             } = json_response(conn, 200)

      # Newest created_at wins; ties break on id desc. `newest` has the latest
      # created_at, so it must come first.
      assert first["id"] == activity.newest.id

      # No total count is returned — the feed is an open-ended log.
      body = json_response(conn, 200)
      refute Map.has_key?(body["data"], "totalCount")
      refute Map.has_key?(body["data"], "total_count")
    end

    test "preserves the agreed camelCase fields and nested objects", %{
      conn: conn,
      activity: activity
    } do
      conn =
        conn
        |> auth_conn("admin")
        |> get("/api/inventory/activity")

      assert %{"data" => %{"activity" => entries}} = json_response(conn, 200)

      # The moved fixture carries item + old/new containers, so all nested
      # objects are populated on that row.
      moved = activity.moved
      entry = Enum.find(entries, &(&1["id"] == moved.id))

      assert entry["id"] == moved.id
      assert entry["action"] == "moved"
      assert entry["changedBy"] == moved.changed_by
      assert entry["createdAt"] == DateTime.to_iso8601(moved.created_at)
      assert entry["itemId"] == moved.item_id
      assert entry["oldContainerId"] == moved.old_container_id
      assert entry["newContainerId"] == moved.new_container_id
      assert entry["notes"] == moved.notes

      assert entry["item"] == %{
               "id" => activity.item.id,
               "attributes" => %{"name" => "Longsword"}
             }

      assert entry["oldContainer"] == %{
               "id" => activity.old_container.id,
               "name" => activity.old_container.name
             }

      assert entry["newContainer"] == %{
               "id" => activity.new_container.id,
               "name" => activity.new_container.name
             }

      # Storage vocabulary must not leak.
      refute Map.has_key?(entry, "changed_by")
      refute Map.has_key?(entry, "item_id")
      refute Map.has_key?(entry, "old_container_id")
      refute Map.has_key?(entry, "new_container_id")
      refute Map.has_key?(entry, "created_at")
    end

    test "nested item/containers are null when the join misses", %{conn: conn, activity: activity} do
      # The `newest` fixture (an `updated` action) has no old/new container, so
      # those nested objects must be null while `item` is populated.
      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/activity")

      assert %{"data" => %{"activity" => entries}} = json_response(conn, 200)

      updated_entry = Enum.find(entries, &(&1["id"] == activity.newest.id))

      assert updated_entry["item"] == %{
               "id" => activity.item.id,
               "attributes" => %{"name" => "Longsword"}
             }

      assert updated_entry["oldContainer"] == nil
      assert updated_entry["newContainer"] == nil
      assert updated_entry["oldContainerId"] == nil
      assert updated_entry["newContainerId"] == nil
    end
  end

  describe "activity — pagination" do
    setup :seed_paginated_activity

    test "paginates forward via cursor and stops with a null nextCursor", %{
      conn: conn,
      rows: rows
    } do
      first_page =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/activity", limit: 10)

      assert %{
               "data" => %{
                 "activity" => first_activity,
                 "nextCursor" => next_cursor
               }
             } = json_response(first_page, 200)

      assert length(first_activity) == 10

      # The first page is the 10 newest rows.
      expected_first_ids =
        rows
        |> Enum.sort_by(&{DateTime.to_iso8601(&1.created_at), &1.id}, :desc)
        |> Enum.take(10)
        |> Enum.map(& &1.id)

      assert Enum.map(first_activity, & &1["id"]) == expected_first_ids

      assert is_binary(next_cursor)

      second_page =
        build_conn()
        |> auth_conn("quartermaster")
        |> get("/api/inventory/activity", limit: 10, cursor: next_cursor)

      assert %{
               "data" => %{
                 "activity" => second_activity,
                 "nextCursor" => nil
               }
             } = json_response(second_page, 200)

      assert length(second_activity) == 5

      all_ids = Enum.map(first_activity, & &1["id"]) ++ Enum.map(second_activity, & &1["id"])
      assert length(all_ids) == 15
      assert Enum.uniq(all_ids) == all_ids
    end

    test "returns 400 for an invalid cursor", %{conn: conn} do
      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/activity", cursor: "not-a-cursor")

      assert %{"errors" => %{"detail" => "Invalid or mismatched cursor"}} =
               json_response(conn, 400)
    end

    test "returns 400 when the cursor was minted with a different limit", %{
      conn: conn,
      rows: _rows
    } do
      cursor =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/activity", limit: 10)
        |> json_response(200)
        |> get_in(["data", "nextCursor"])

      # Reuse the limit=10 cursor with limit=25 — must be rejected.
      conn =
        build_conn()
        |> auth_conn("quartermaster")
        |> get("/api/inventory/activity", limit: 25, cursor: cursor)

      assert %{"errors" => %{"detail" => "Invalid or mismatched cursor"}} =
               json_response(conn, 400)
    end

    test "returns 400 for an invalid limit", %{conn: conn} do
      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/activity", limit: 7)

      assert %{"errors" => %{"detail" => "Invalid limit"}} = json_response(conn, 400)
    end
  end

  describe "activity — filters" do
    setup :seed_filterable_activity

    test "filters by itemId", %{conn: conn, activity: activity} do
      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/activity", itemId: activity.item_b.id)

      assert %{"data" => %{"activity" => entries}} = json_response(conn, 200)

      assert Enum.all?(entries, &(&1["itemId"] == activity.item_b.id))
    end

    test "filters by containerId (matches old or new container)", %{
      conn: conn,
      activity: activity
    } do
      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/activity", containerId: activity.container_b.id)

      assert %{"data" => %{"activity" => entries}} = json_response(conn, 200)

      # Both rows touching container B (moved-from-B and moved-to-B) appear.
      ids = Enum.map(entries, & &1["id"]) |> MapSet.new()

      assert MapSet.member?(ids, activity.moved_from_b.id)
      assert MapSet.member?(ids, activity.moved_to_b.id)
    end

    test "returns 400 for an invalid itemId", %{conn: conn} do
      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/activity", itemId: "not-a-uuid")

      assert %{"errors" => %{"detail" => "Invalid itemId"}} = json_response(conn, 400)
    end

    test "returns 400 for an invalid containerId", %{conn: conn} do
      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/activity", containerId: "not-a-uuid")

      assert %{"errors" => %{"detail" => "Invalid containerId"}} = json_response(conn, 400)
    end
  end

  # ── Item filter options (ALE-98) ─────────────────────────────────────

  describe "filters — RBAC" do
    test "allows quartermaster, president, and admin", %{conn: _conn} do
      for role <- @allowed_roles do
        conn =
          build_conn()
          |> auth_conn(role)
          |> get("/api/inventory/items/filters")

        assert %{"data" => %{"categories" => _, "containers" => _}} =
                 json_response(conn, 200)
      end
    end

    test "returns 401 without a bearer token", %{conn: conn} do
      conn = get(conn, "/api/inventory/items/filters")

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "returns 401 with an invalid bearer token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer bad-token")
        |> get("/api/inventory/items/filters")

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "returns 403 for members without an Inventory privilege", %{conn: _conn} do
      for role <- @rejected_roles do
        conn =
          build_conn()
          |> auth_conn(role)
          |> get("/api/inventory/items/filters")

        assert %{"errors" => %{"detail" => "Insufficient role"}} =
                 json_response(conn, 403)
      end
    end
  end

  describe "filters — payload" do
    # The baseline migration (`20260512000010_create_inventory`) seeds 7
    # default equipment categories (Masks, Gorgets, …). Clear them so the
    # category list assertion is deterministic.
    setup do
      Repo.delete_all(InventoryItem)
      Repo.delete_all(Container)
      Repo.delete_all(EquipmentCategory)
      :ok
    end

    test "returns empty category and container arrays when nothing is seeded",
         %{conn: conn} do
      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/items/filters")

      assert json_response(conn, 200) == %{
               "data" => %{"categories" => [], "containers" => []}
             }
    end

    test "returns categories and containers ordered by name asc, camelCased",
         %{conn: conn} do
      # Categories inserted out of order; the response must be name-sorted.
      InventoryFixtures.category_fixture(name: "Zweihänder")
      InventoryFixtures.category_fixture(name: "Axes")
      InventoryFixtures.category_fixture(name: "Masks")

      # Containers inserted out of order; the response must be name-sorted.
      parent = InventoryFixtures.container_fixture(name: "Storage Room")
      InventoryFixtures.container_fixture(name: "Shelf Z")
      InventoryFixtures.container_fixture(name: "Shelf A")
      InventoryFixtures.container_fixture(name: "Shelf M", parent_container_id: parent.id)

      conn =
        conn
        |> auth_conn("admin")
        |> get("/api/inventory/items/filters")

      assert %{
               "data" => %{
                 "categories" => categories,
                 "containers" => containers
               }
             } = json_response(conn, 200)

      assert Enum.map(categories, & &1["name"]) == ["Axes", "Masks", "Zweihänder"]

      assert Enum.map(containers, & &1["name"]) == [
               "Shelf A",
               "Shelf M",
               "Shelf Z",
               "Storage Room"
             ]

      # Spot-check the camelCase shape on one category + one container.
      [axes | _] = categories

      assert axes["id"] != nil
      assert axes["description"] != nil
      assert axes["availableAttributes"] == []
      assert axes["attributeSchema"] == %{}
      # Storage vocabulary must not leak.
      refute Map.has_key?(axes, "available_attributes")
      refute Map.has_key?(axes, "attribute_schema")
      refute Map.has_key?(axes, "inserted_at")
      refute Map.has_key?(axes, "created_at")
      refute Map.has_key?(axes, "updated_at")

      shelf_m =
        Enum.find(containers, &(&1["name"] == "Shelf M"))

      assert shelf_m["id"] != nil
      assert shelf_m["description"] != nil
      assert shelf_m["parentContainerId"] == parent.id
      refute Map.has_key?(shelf_m, "parent_container_id")
      refute Map.has_key?(shelf_m, "created_by")
      refute Map.has_key?(shelf_m, "inserted_at")
      refute Map.has_key?(shelf_m, "created_at")
      refute Map.has_key?(shelf_m, "updated_at")
    end

    test "preserves availableAttributes definition shapes round-tripped from jsonb",
         %{conn: conn} do
      InventoryFixtures.category_fixture(
        name: "Masks",
        available_attributes: [
          %{"name" => "brand", "type" => "text", "required" => true, "label" => "Brand"},
          %{
            "name" => "size",
            "type" => "select",
            "options" => ["XS", "S", "M", "L", "XL"],
            "required" => false,
            "label" => "Size"
          }
        ],
        attribute_schema: %{"type" => "object"}
      )

      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/items/filters")

      assert %{"data" => %{"categories" => [category]}} = json_response(conn, 200)

      assert category["availableAttributes"] == [
               %{"name" => "brand", "type" => "text", "required" => true, "label" => "Brand"},
               %{
                 "name" => "size",
                 "type" => "select",
                 "options" => ["XS", "S", "M", "L", "XL"],
                 "required" => false,
                 "label" => "Size"
               }
             ]

      assert category["attributeSchema"] == %{"type" => "object"}
    end

    test "container parentContainerId is null for top-level containers", %{conn: conn} do
      InventoryFixtures.container_fixture(name: "Locker A")

      conn =
        conn
        |> auth_conn("president")
        |> get("/api/inventory/items/filters")

      assert %{"data" => %{"containers" => [container]}} = json_response(conn, 200)

      assert container["parentContainerId"] == nil
    end

    test "uses the data envelope and does not leak storage vocabulary", %{conn: conn} do
      InventoryFixtures.category_fixture(name: "Masks")
      InventoryFixtures.container_fixture(name: "Locker A")

      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/items/filters")

      body = json_response(conn, 200)

      assert %{"data" => %{"categories" => _, "containers" => _}} = body

      # Storage vocabulary must not leak into the contract.
      refute Map.has_key?(body, "equipment_categories")
      refute Map.has_key?(body, "containers_rows")
      refute Map.has_key?(body["data"], "equipment_categories")
    end
  end

  # ── Equipment Category list (ALE-96) ──────────────────────────────────

  describe "categories — RBAC" do
    test "allows quartermaster, president, and admin", %{conn: _conn} do
      for role <- @allowed_roles do
        conn =
          build_conn()
          |> auth_conn(role)
          |> get("/api/inventory/categories")

        assert %{"data" => %{"categories" => _}} = json_response(conn, 200)
      end
    end

    test "returns 401 without a bearer token", %{conn: conn} do
      conn = get(conn, "/api/inventory/categories")

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "returns 401 with an invalid bearer token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer bad-token")
        |> get("/api/inventory/categories")

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "returns 403 for members without an Inventory privilege", %{conn: _conn} do
      for role <- @rejected_roles do
        conn =
          build_conn()
          |> auth_conn(role)
          |> get("/api/inventory/categories")

        assert %{"errors" => %{"detail" => "Insufficient role"}} =
                 json_response(conn, 403)
      end
    end
  end

  describe "categories — payload" do
    # The baseline migration (`20260512000010_create_inventory`) seeds 7
    # default equipment categories (Masks, Gorgets, …). Clear them plus
    # containers/items so the category list assertion is deterministic.
    setup do
      Repo.delete_all(InventoryItem)
      Repo.delete_all(Container)
      Repo.delete_all(EquipmentCategory)
      :ok
    end

    test "returns an empty category array when nothing is seeded", %{conn: conn} do
      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/categories")

      assert json_response(conn, 200) == %{"data" => %{"categories" => []}}
    end

    test "returns categories ordered by name asc, camelCased", %{conn: conn} do
      # Categories inserted out of order; the response must be name-sorted.
      InventoryFixtures.category_fixture(name: "Zweihänder")
      InventoryFixtures.category_fixture(name: "Axes")
      InventoryFixtures.category_fixture(name: "Masks")

      conn =
        conn
        |> auth_conn("admin")
        |> get("/api/inventory/categories")

      assert %{"data" => %{"categories" => categories}} = json_response(conn, 200)

      assert Enum.map(categories, & &1["name"]) == ["Axes", "Masks", "Zweihänder"]
    end

    test "preserves the agreed camelCase fields and no storage-vocab leak", %{conn: conn} do
      InventoryFixtures.category_fixture(
        name: "Masks",
        available_attributes: [%{"name" => "brand", "type" => "text", "label" => "Brand"}]
      )

      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/categories")

      assert %{"data" => %{"categories" => [category]}} = json_response(conn, 200)

      assert category["id"] != nil
      assert category["name"] == "Masks"
      assert category["description"] != nil

      assert category["availableAttributes"] == [
               %{"name" => "brand", "type" => "text", "label" => "Brand"}
             ]

      # itemCount is present (zero here — no items seeded).
      assert category["itemCount"] == 0

      # Storage vocabulary must not leak into the contract.
      refute Map.has_key?(category, "available_attributes")
      refute Map.has_key?(category, "item_count")
      refute Map.has_key?(category, "inserted_at")
      refute Map.has_key?(category, "created_at")
      refute Map.has_key?(category, "updated_at")
      refute Map.has_key?(category, "created_at")
      refute Map.has_key?(category, "created_by")
    end

    test "itemCount counts the Inventory Items in each category", %{conn: conn} do
      masks = InventoryFixtures.category_fixture(name: "Masks")
      gloves = InventoryFixtures.category_fixture(name: "Gloves")
      container = InventoryFixtures.container_fixture()

      # Three Masks items, one Gloves item.
      InventoryFixtures.item_fixture(container_id: container.id, category_id: masks.id)
      InventoryFixtures.item_fixture(container_id: container.id, category_id: masks.id)
      InventoryFixtures.item_fixture(container_id: container.id, category_id: masks.id)
      InventoryFixtures.item_fixture(container_id: container.id, category_id: gloves.id)

      conn =
        conn
        |> auth_conn("president")
        |> get("/api/inventory/categories")

      assert %{"data" => %{"categories" => categories}} = json_response(conn, 200)

      by_name = Map.new(categories, &{&1["name"], &1["itemCount"]})

      assert by_name["Masks"] == 3
      assert by_name["Gloves"] == 1
    end

    test "itemCount is zero for a category with no Inventory Items", %{conn: conn} do
      InventoryFixtures.category_fixture(name: "Masks")

      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/categories")

      assert %{"data" => %{"categories" => [category]}} = json_response(conn, 200)

      assert category["itemCount"] == 0
    end

    test "uses the data envelope and does not leak storage vocabulary", %{conn: conn} do
      InventoryFixtures.category_fixture(name: "Masks")

      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/categories")

      body = json_response(conn, 200)

      assert %{"data" => %{"categories" => _}} = body

      # Storage vocabulary must not leak into the contract.
      refute Map.has_key?(body, "equipment_categories")
      refute Map.has_key?(body["data"], "equipment_categories")
    end
  end

  # ── Container list (ALE-97) ───────────────────────────────────────────

  describe "containers — RBAC" do
    test "allows quartermaster, president, and admin", %{conn: _conn} do
      for role <- @allowed_roles do
        conn =
          build_conn()
          |> auth_conn(role)
          |> get("/api/inventory/containers")

        assert %{"data" => %{"containers" => _}} = json_response(conn, 200)
      end
    end

    test "returns 401 without a bearer token", %{conn: conn} do
      conn = get(conn, "/api/inventory/containers")

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "returns 401 with an invalid bearer token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer bad-token")
        |> get("/api/inventory/containers")

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "returns 403 for members without an Inventory privilege", %{conn: _conn} do
      for role <- @rejected_roles do
        conn =
          build_conn()
          |> auth_conn(role)
          |> get("/api/inventory/containers")

        assert %{"errors" => %{"detail" => "Insufficient role"}} =
                 json_response(conn, 403)
      end
    end
  end

  describe "containers — payload" do
    # Clear all inventory rows so assertions are deterministic.
    setup do
      Repo.delete_all(InventoryItem)
      Repo.delete_all(Container)
      Repo.delete_all(EquipmentCategory)
      :ok
    end

    test "returns an empty container array when nothing is seeded", %{conn: conn} do
      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/containers")

      assert json_response(conn, 200) == %{"data" => %{"containers" => []}}
    end

    test "returns containers ordered by name asc, camelCased", %{conn: conn} do
      # Containers inserted out of order; the response must be name-sorted.
      InventoryFixtures.container_fixture(name: "Locker Z")
      InventoryFixtures.container_fixture(name: "Locker A")
      InventoryFixtures.container_fixture(name: "Locker M")

      conn =
        conn
        |> auth_conn("admin")
        |> get("/api/inventory/containers")

      assert %{"data" => %{"containers" => containers}} = json_response(conn, 200)

      assert Enum.map(containers, & &1["name"]) == ["Locker A", "Locker M", "Locker Z"]
    end

    test "preserves the agreed camelCase fields and no storage-vocab leak for a top-level container",
         %{conn: conn} do
      InventoryFixtures.container_fixture(name: "Locker A")

      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/containers")

      assert %{"data" => %{"containers" => [container]}} = json_response(conn, 200)

      assert container["id"] != nil
      assert container["name"] == "Locker A"
      assert container["description"] != nil

      # A top-level container has no parent.
      assert container["parentContainerId"] == nil
      assert container["parentContainer"] == nil

      # itemCount is present (zero here — no items seeded).
      assert container["itemCount"] == 0

      # Storage vocabulary must not leak into the contract.
      refute Map.has_key?(container, "parent_container_id")
      refute Map.has_key?(container, "parent_container")
      refute Map.has_key?(container, "item_count")
      refute Map.has_key?(container, "inserted_at")
      refute Map.has_key?(container, "created_at")
      refute Map.has_key?(container, "updated_at")
      refute Map.has_key?(container, "created_at")
      refute Map.has_key?(container, "created_by")
    end

    test "parentContainer is the nested {id, name} object for a nested container",
         %{conn: conn} do
      parent = InventoryFixtures.container_fixture(name: "Storage Room")
      InventoryFixtures.container_fixture(name: "Shelf", parent_container_id: parent.id)

      conn =
        conn
        |> auth_conn("president")
        |> get("/api/inventory/containers")

      assert %{"data" => %{"containers" => containers}} = json_response(conn, 200)

      shelf =
        Enum.find(containers, &(&1["name"] == "Shelf"))

      assert shelf["parentContainerId"] == parent.id
      assert shelf["parentContainer"] == %{"id" => parent.id, "name" => "Storage Room"}
    end

    test "itemCount counts the Inventory Items directly in each container", %{conn: conn} do
      locker_a = InventoryFixtures.container_fixture(name: "Locker A")
      locker_b = InventoryFixtures.container_fixture(name: "Locker B")
      category = InventoryFixtures.category_fixture()

      # Three items in Locker A, one item in Locker B.
      InventoryFixtures.item_fixture(container_id: locker_a.id, category_id: category.id)
      InventoryFixtures.item_fixture(container_id: locker_a.id, category_id: category.id)
      InventoryFixtures.item_fixture(container_id: locker_a.id, category_id: category.id)
      InventoryFixtures.item_fixture(container_id: locker_b.id, category_id: category.id)

      conn =
        conn
        |> auth_conn("president")
        |> get("/api/inventory/containers")

      assert %{"data" => %{"containers" => containers}} = json_response(conn, 200)

      by_name = Map.new(containers, &{&1["name"], &1["itemCount"]})

      assert by_name["Locker A"] == 3
      assert by_name["Locker B"] == 1
    end

    test "itemCount is zero for a container with no Inventory Items", %{conn: conn} do
      InventoryFixtures.container_fixture(name: "Locker A")

      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/containers")

      assert %{"data" => %{"containers" => [container]}} = json_response(conn, 200)

      assert container["itemCount"] == 0
    end

    test "uses the data envelope and does not leak storage vocabulary", %{conn: conn} do
      InventoryFixtures.container_fixture(name: "Locker A")

      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/containers")

      body = json_response(conn, 200)

      assert %{"data" => %{"containers" => _}} = body

      # Storage vocabulary must not leak into the contract.
      refute Map.has_key?(body, "containers_rows")
      refute Map.has_key?(body["data"], "inventory_items")
      refute Map.has_key?(body["data"], "equipment_categories")
    end
  end

  # ── Inventory Item list (ALE-99) ─────────────────────────────────────

  describe "items — RBAC" do
    test "allows quartermaster, president, and admin", %{conn: _conn} do
      for role <- @allowed_roles do
        conn =
          build_conn()
          |> auth_conn(role)
          |> get("/api/inventory/items")

        assert %{"data" => %{"items" => _}} = json_response(conn, 200)
      end
    end

    test "returns 401 without a bearer token", %{conn: conn} do
      conn = get(conn, "/api/inventory/items")

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "returns 401 with an invalid bearer token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer bad-token")
        |> get("/api/inventory/items")

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "returns 403 for members without an Inventory privilege", %{conn: _conn} do
      for role <- @rejected_roles do
        conn =
          build_conn()
          |> auth_conn(role)
          |> get("/api/inventory/items")

        assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
      end
    end
  end

  describe "items — payload" do
    setup do
      Repo.delete_all(InventoryItem)
      Repo.delete_all(Container)
      Repo.delete_all(EquipmentCategory)
      :ok
    end

    test "returns an empty item array with zero totalCount when nothing is seeded",
         %{conn: conn} do
      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/items")

      assert json_response(conn, 200) == %{
               "data" => %{
                 "items" => [],
                 "limit" => 10,
                 "totalCount" => 0,
                 "nextCursor" => nil,
                 "previousCursor" => nil
               }
             }
    end

    test "returns items ordered by createdAt desc, id desc (newest first)", %{conn: conn} do
      category = InventoryFixtures.category_fixture(name: "Masks")
      container = InventoryFixtures.container_fixture(name: "Locker A")

      older =
        InventoryFixtures.item_fixture(
          container_id: container.id,
          category_id: category.id,
          created_at: ~U[2026-01-01 00:00:00Z]
        )

      newer =
        InventoryFixtures.item_fixture(
          container_id: container.id,
          category_id: category.id,
          created_at: ~U[2026-01-02 00:00:00Z]
        )

      conn =
        conn
        |> auth_conn("admin")
        |> get("/api/inventory/items")

      assert %{"data" => %{"items" => items}} = json_response(conn, 200)

      assert Enum.map(items, & &1["id"]) == [newer.id, older.id]
    end

    test "preserves the agreed camelCase fields and no storage-vocab leak", %{conn: conn} do
      category = InventoryFixtures.category_fixture(name: "Masks")
      container = InventoryFixtures.container_fixture(name: "Locker A")

      InventoryFixtures.item_fixture(
        container_id: container.id,
        category_id: category.id,
        attributes: %{"name" => "Mask A", "brand" => "SPES"}
      )

      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/items")

      assert %{"data" => %{"items" => [item]}} = json_response(conn, 200)

      assert item["id"] != nil
      assert item["quantity"] == 1
      assert item["maintenanceStatus"] == "available"
      assert item["attributes"] == %{"name" => "Mask A", "brand" => "SPES"}

      assert item["category"] == %{"id" => category.id, "name" => "Masks"}
      assert item["container"] == %{"id" => container.id, "name" => "Locker A"}

      # Storage vocabulary must not leak into the contract.
      refute Map.has_key?(item, "out_for_maintenance")
      refute Map.has_key?(item, "maintenance_status")
      refute Map.has_key?(item, "inserted_at")
      refute Map.has_key?(item, "created_at")
      refute Map.has_key?(item, "updated_at")
      refute Map.has_key?(item, "created_by")
      refute Map.has_key?(item, "updated_by")
      refute Map.has_key?(item, "category_id")
      refute Map.has_key?(item, "container_id")
    end

    test "maintenanceStatus is the domain term (available / inMaintenance)", %{conn: conn} do
      category = InventoryFixtures.category_fixture(name: "Masks")
      container = InventoryFixtures.container_fixture(name: "Locker A")

      InventoryFixtures.item_fixture(
        container_id: container.id,
        category_id: category.id,
        out_for_maintenance: false
      )

      InventoryFixtures.item_fixture(
        container_id: container.id,
        category_id: category.id,
        out_for_maintenance: true
      )

      conn =
        conn
        |> auth_conn("president")
        |> get("/api/inventory/items")

      assert %{"data" => %{"items" => items}} = json_response(conn, 200)

      statuses = Enum.map(items, & &1["maintenanceStatus"]) |> Enum.sort()

      assert statuses == ["available", "inMaintenance"]
    end

    test "totalCount counts every item matching the current filters", %{conn: conn} do
      category = InventoryFixtures.category_fixture(name: "Masks")
      container = InventoryFixtures.container_fixture(name: "Locker A")

      for _ <- 1..3 do
        InventoryFixtures.item_fixture(container_id: container.id, category_id: category.id)
      end

      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/items")

      assert %{"data" => %{"items" => items, "totalCount" => total}} = json_response(conn, 200)

      assert length(items) == 3
      assert total == 3
    end

    test "uses the data envelope and does not leak storage vocabulary", %{conn: conn} do
      InventoryFixtures.category_fixture(name: "Masks")

      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/items")

      body = json_response(conn, 200)

      assert %{"data" => %{"items" => _}} = body

      refute Map.has_key?(body, "inventory_items")
      refute Map.has_key?(body["data"], "inventory_items")
      refute Map.has_key?(body["data"], "equipment_categories")
    end
  end

  describe "items — pagination" do
    setup :seed_paginated_items

    test "paginates forward via cursor and stops with a null nextCursor", %{
      conn: conn,
      items: items
    } do
      first_page =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/items", limit: 10)

      assert %{
               "data" => %{
                 "items" => first_items,
                 "totalCount" => 15,
                 "nextCursor" => next_cursor,
                 "previousCursor" => nil
               }
             } = json_response(first_page, 200)

      assert length(first_items) == 10
      assert is_binary(next_cursor)

      expected_first_ids =
        items
        |> Enum.sort_by(&{&1.created_at, &1.id}, :desc)
        |> Enum.take(10)
        |> Enum.map(& &1.id)

      assert Enum.map(first_items, & &1["id"]) == expected_first_ids

      second_page =
        build_conn()
        |> auth_conn("quartermaster")
        |> get("/api/inventory/items", limit: 10, cursor: next_cursor)

      assert %{
               "data" => %{
                 "items" => second_items,
                 "totalCount" => 15,
                 "nextCursor" => nil,
                 "previousCursor" => previous_cursor
               }
             } = json_response(second_page, 200)

      assert length(second_items) == 5
      assert is_binary(previous_cursor)

      all_ids = Enum.map(first_items, & &1["id"]) ++ Enum.map(second_items, & &1["id"])
      assert length(all_ids) == 15
      assert Enum.uniq(all_ids) == all_ids
    end

    test "returns 400 for an invalid cursor", %{conn: conn} do
      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/items", cursor: "not-a-cursor")

      assert %{"errors" => %{"detail" => "Invalid or mismatched cursor"}} =
               json_response(conn, 400)
    end

    test "returns 400 when the cursor was minted with a different limit", %{
      conn: conn,
      items: _items
    } do
      cursor =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/items", limit: 10)
        |> json_response(200)
        |> get_in(["data", "nextCursor"])

      conn =
        build_conn()
        |> auth_conn("quartermaster")
        |> get("/api/inventory/items", limit: 25, cursor: cursor)

      assert %{"errors" => %{"detail" => "Invalid or mismatched cursor"}} =
               json_response(conn, 400)
    end

    test "returns 400 for an invalid limit", %{conn: conn} do
      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/items", limit: 7)

      assert %{"errors" => %{"detail" => "Invalid limit"}} = json_response(conn, 400)
    end
  end

  describe "items — filters" do
    setup :seed_filterable_items

    test "filters by categoryId", %{conn: conn, items: items} do
      masks_id = items.masks.id

      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/items", categoryId: masks_id)

      assert %{"data" => %{"items" => items_response, "totalCount" => total}} =
               json_response(conn, 200)

      # Three Masks items (longsword, in_b, in_maintenance).
      assert length(items_response) == 3
      assert total == 3
      assert Enum.all?(items_response, &(&1["category"]["id"] == masks_id))
    end

    test "filters by containerId", %{conn: conn, items: items} do
      locker_a_id = items.locker_a.id

      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/items", containerId: locker_a_id)

      assert %{"data" => %{"items" => items_response, "totalCount" => total}} =
               json_response(conn, 200)

      # Two items in Locker A (longsword, gloves_item).
      assert length(items_response) == 2
      assert total == 2
      assert Enum.all?(items_response, &(&1["container"]["id"] == locker_a_id))
    end

    test "filters by maintenanceStatus=inMaintenance", %{conn: conn} do
      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/items", maintenanceStatus: "inMaintenance")

      assert %{"data" => %{"items" => items, "totalCount" => total}} = json_response(conn, 200)

      assert length(items) == 1
      assert total == 1
      assert hd(items)["maintenanceStatus"] == "inMaintenance"
    end

    test "filters by maintenanceStatus=available", %{conn: conn} do
      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/items", maintenanceStatus: "available")

      assert %{"data" => %{"items" => items, "totalCount" => total}} = json_response(conn, 200)

      # Three available items (longsword, gloves_item, in_b).
      assert length(items) == 3
      assert total == 3
      assert Enum.all?(items, &(&1["maintenanceStatus"] == "available"))
    end

    test "searches across item attributes.name, category name, and container name", %{
      conn: conn,
      items: items
    } do
      # attributes.name match
      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/items", q: "longsword")

      assert %{"data" => %{"items" => found, "totalCount" => 1}} = json_response(conn, 200)

      assert hd(found)["id"] == items.longsword.id

      # category name match
      conn =
        build_conn()
        |> auth_conn("quartermaster")
        |> get("/api/inventory/items", q: "gloves")

      assert %{"data" => %{"items" => found, "totalCount" => 1}} = json_response(conn, 200)

      assert hd(found)["id"] == items.gloves_item.id

      # container name match — both Locker B items (in_b, in_maintenance).
      conn =
        build_conn()
        |> auth_conn("quartermaster")
        |> get("/api/inventory/items", q: "locker b")

      assert %{"data" => %{"items" => found, "totalCount" => 2}} = json_response(conn, 200)

      found_ids = Enum.map(found, & &1["id"]) |> MapSet.new()

      assert MapSet.member?(found_ids, items.in_b.id)
      assert MapSet.member?(found_ids, items.in_maintenance.id)
    end

    test "returns 400 for an invalid categoryId", %{conn: conn} do
      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/items", categoryId: "not-a-uuid")

      assert %{"errors" => %{"detail" => "Invalid categoryId"}} = json_response(conn, 400)
    end

    test "returns 400 for an invalid containerId", %{conn: conn} do
      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/items", containerId: "not-a-uuid")

      assert %{"errors" => %{"detail" => "Invalid containerId"}} = json_response(conn, 400)
    end

    test "returns 400 for an invalid maintenanceStatus", %{conn: conn} do
      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/items", maintenanceStatus: "broken")

      assert %{"errors" => %{"detail" => "Invalid maintenanceStatus"}} = json_response(conn, 400)
    end
  end

  # ── Fixtures ─────────────────────────────────────────────────────────

  defp seed_activity_fixture(_context) do
    # Clear seeded equipment categories so counts/rows are deterministic, and
    # wipe any leftover history from prior tests.
    Repo.delete_all(InventoryActivity)
    Repo.delete_all(InventoryItem)
    Repo.delete_all(Container)
    Repo.delete_all(EquipmentCategory)

    changed_by = InventoryFixtures.auth_user_fixture()
    category = InventoryFixtures.category_fixture(name: "Longswords")

    old_container = InventoryFixtures.container_fixture(name: "Locker A")
    new_container = InventoryFixtures.container_fixture(name: "Locker B")

    item =
      InventoryFixtures.item_fixture(
        container_id: new_container.id,
        category_id: category.id,
        attributes: %{"name" => "Longsword"}
      )

    created =
      InventoryFixtures.activity_fixture(
        item_id: item.id,
        changed_by: changed_by,
        action: "created",
        new_container_id: new_container.id,
        notes: "Initial creation",
        created_at: ~U[2026-01-01 00:00:00Z]
      )

    moved =
      InventoryFixtures.activity_fixture(
        item_id: item.id,
        changed_by: changed_by,
        action: "moved",
        old_container_id: old_container.id,
        new_container_id: new_container.id,
        notes: "Moved A → B",
        created_at: ~U[2026-01-02 00:00:00Z]
      )

    newest =
      InventoryFixtures.activity_fixture(
        item_id: item.id,
        changed_by: changed_by,
        action: "updated",
        notes: "Attribute refresh",
        created_at: ~U[2026-01-03 00:00:00Z]
      )

    {:ok,
     activity: %{
       item: item,
       old_container: old_container,
       new_container: new_container,
       created: created,
       moved: moved,
       newest: newest
     }}
  end

  defp seed_paginated_activity(_context) do
    Repo.delete_all(InventoryActivity)
    Repo.delete_all(InventoryItem)
    Repo.delete_all(Container)
    Repo.delete_all(EquipmentCategory)

    changed_by = InventoryFixtures.auth_user_fixture()
    category = InventoryFixtures.category_fixture()
    container = InventoryFixtures.container_fixture()
    item = InventoryFixtures.item_fixture(container_id: container.id, category_id: category.id)

    rows =
      for index <- 1..15 do
        InventoryFixtures.activity_fixture(
          item_id: item.id,
          changed_by: changed_by,
          action: "updated",
          notes: "Update #{index}",
          created_at: DateTime.add(~U[2026-01-01 00:00:00Z], index, :second)
        )
      end

    {:ok, rows: rows}
  end

  defp seed_filterable_activity(_context) do
    Repo.delete_all(InventoryActivity)
    Repo.delete_all(InventoryItem)
    Repo.delete_all(Container)
    Repo.delete_all(EquipmentCategory)

    changed_by = InventoryFixtures.auth_user_fixture()
    category = InventoryFixtures.category_fixture()

    container_a = InventoryFixtures.container_fixture(name: "Container A")
    container_b = InventoryFixtures.container_fixture(name: "Container B")

    item_a =
      InventoryFixtures.item_fixture(
        container_id: container_a.id,
        category_id: category.id,
        attributes: %{"name" => "Item A"}
      )

    item_b =
      InventoryFixtures.item_fixture(
        container_id: container_b.id,
        category_id: category.id,
        attributes: %{"name" => "Item B"}
      )

    moved_from_b =
      InventoryFixtures.activity_fixture(
        item_id: item_b.id,
        changed_by: changed_by,
        action: "moved",
        old_container_id: container_b.id,
        new_container_id: container_a.id,
        created_at: ~U[2026-01-02 00:00:00Z]
      )

    moved_to_b =
      InventoryFixtures.activity_fixture(
        item_id: item_a.id,
        changed_by: changed_by,
        action: "moved",
        old_container_id: container_a.id,
        new_container_id: container_b.id,
        created_at: ~U[2026-01-03 00:00:00Z]
      )

    {:ok,
     activity: %{
       item_a: item_a,
       item_b: item_b,
       container_a: container_a,
       container_b: container_b,
       moved_from_b: moved_from_b,
       moved_to_b: moved_to_b
     }}
  end

  defp seed_paginated_items(_context) do
    Repo.delete_all(InventoryActivity)
    Repo.delete_all(InventoryItem)
    Repo.delete_all(Container)
    Repo.delete_all(EquipmentCategory)

    category = InventoryFixtures.category_fixture(name: "Masks")
    container = InventoryFixtures.container_fixture(name: "Locker A")

    items =
      for index <- 1..15 do
        InventoryFixtures.item_fixture(
          container_id: container.id,
          category_id: category.id,
          created_at: DateTime.add(~U[2026-01-01 00:00:00Z], index, :second)
        )
      end

    {:ok, items: items}
  end

  defp seed_filterable_items(_context) do
    Repo.delete_all(InventoryActivity)
    Repo.delete_all(InventoryItem)
    Repo.delete_all(Container)
    Repo.delete_all(EquipmentCategory)

    masks = InventoryFixtures.category_fixture(name: "Masks")
    gloves = InventoryFixtures.category_fixture(name: "Gloves")
    locker_a = InventoryFixtures.container_fixture(name: "Locker A")
    locker_b = InventoryFixtures.container_fixture(name: "Locker B")

    # attributes.name match ("longsword")
    longsword =
      InventoryFixtures.item_fixture(
        container_id: locker_a.id,
        category_id: masks.id,
        attributes: %{"name" => "Longsword Premium"}
      )

    # category name match ("gloves")
    gloves_item =
      InventoryFixtures.item_fixture(
        container_id: locker_a.id,
        category_id: gloves.id,
        attributes: %{"name" => "Generic Item"}
      )

    # container name match ("locker b")
    in_b =
      InventoryFixtures.item_fixture(
        container_id: locker_b.id,
        category_id: masks.id,
        attributes: %{"name" => "Other Item"}
      )

    # no match — in maintenance, used by the maintenance filter tests too
    in_maintenance =
      InventoryFixtures.item_fixture(
        container_id: locker_b.id,
        category_id: masks.id,
        attributes: %{"name" => "Maintenance Item"},
        out_for_maintenance: true
      )

    {:ok,
     items: %{
       masks: masks,
       gloves: gloves,
       locker_a: locker_a,
       locker_b: locker_b,
       longsword: longsword,
       gloves_item: gloves_item,
       in_b: in_b,
       in_maintenance: in_maintenance
     }}
  end
end
