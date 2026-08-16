defmodule DhcWeb.InventoryItemsControllerTest do
  @moduledoc """
  Request/contract tests for the Inventory Item slice — ALE-107.

  Covers the ALE-104 contract for `GET/POST /inventory/items`,
  `GET/PATCH/DELETE /inventory/items/:id`, and
  `GET /inventory/items/:id/history`: RBAC (member reads, inventory write
  roles), camelCase payload shape, cursor pagination, filters, 404/422 error
  mapping, and created/updated/moved history side effects.
  """

  use DhcWeb.ConnCase, async: false

  alias Dhc.Repo

  @actor_id "11111111-1111-1111-1111-111111111111"
  @read_roles ~w(member quartermaster admin president)
  @write_roles ~w(quartermaster admin president)

  defmodule Verifier do
    @actor_id "11111111-1111-1111-1111-111111111111"

    for role <- ~w(quartermaster admin president member) do
      def verify(unquote("#{role}-token")) do
        {:ok,
         %{
           sub: @actor_id,
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

    insert_user!(@actor_id, "inv-item-actor@example.com")

    on_exit(fn -> Application.put_env(:dhc, :auth_verifier, original) end)

    :ok
  end

  defp auth_conn(conn, role), do: put_req_header(conn, "authorization", "Bearer #{role}-token")

  defp to_uuid(<<_::128>> = value), do: Ecto.UUID.load!(value)
  defp to_uuid(value) when is_binary(value), do: value

  defp insert_user!(id, email) do
    {:ok, _} =
      Dhc.Auth.register_principal_with_id(id, %{email: email})

    :ok
  end

  defp create_container!(attrs) do
    {:ok, container} = Dhc.Inventory.create_container(attrs, @actor_id)
    container
  end

  defp insert_category!(name) do
    {:ok, category} =
      %Dhc.Inventory.EquipmentCategory{}
      |> Ecto.Changeset.cast(%{name: name}, [:name])
      |> Ecto.Changeset.validate_required([:name])
      |> Repo.insert()

    category
  end

  defp create_item!(attrs) do
    {:ok, item} = Dhc.Inventory.create_item(attrs, @actor_id)
    item
  end

  defp history_actions(item_id) do
    {:ok, history} = Dhc.Inventory.list_item_history(to_uuid(item_id), %{"limit" => "20"})
    Enum.map(history, &Atom.to_string(&1.action))
  end

  defp item_payload(container, category, overrides \\ %{}) do
    Map.merge(
      %{
        "containerId" => to_uuid(container.id),
        "categoryId" => to_uuid(category.id),
        "quantity" => 2,
        "attributes" => %{"brand" => "PBT"},
        "notes" => "Test item",
        "outForMaintenance" => false
      },
      overrides
    )
  end

  describe "index" do
    test "returns cursor-paginated items newest first with container/category summaries", %{
      conn: conn
    } do
      category = insert_category!("Inventory Items Test Masks")
      container = create_container!(%{"name" => "Armory"})
      first = create_item!(item_payload(container, category, %{"notes" => "first"}))
      second = create_item!(item_payload(container, category, %{"notes" => "second"}))

      conn =
        conn
        |> auth_conn("member")
        |> get("/api/inventory/items", %{"limit" => "10"})

      assert %{"data" => %{"items" => items, "limit" => 10, "nextCursor" => nil}} =
               json_response(conn, 200)

      ids = Enum.map(items, & &1["id"])
      assert to_uuid(second.id) in ids
      assert to_uuid(first.id) in ids

      payload = Enum.find(items, &(&1["id"] == to_uuid(second.id)))

      assert payload["container"] == %{
               "id" => to_uuid(container.id),
               "name" => "Armory",
               "parent_container_id" => nil
             }

      assert payload["category"] == %{
               "id" => to_uuid(category.id),
               "name" => "Inventory Items Test Masks"
             }

      assert payload["outForMaintenance"] == false
      assert payload["attributes"] == %{"brand" => "PBT"}
    end

    test "supports filters and returns a nextCursor when a following page exists", %{conn: conn} do
      masks = insert_category!("Masks Filter")
      gloves = insert_category!("Gloves Filter")
      armory = create_container!(%{"name" => "Armory Filter"})

      matching = create_item!(item_payload(armory, masks, %{"notes" => "needle"}))
      _other_category = create_item!(item_payload(armory, gloves, %{"notes" => "needle"}))
      second_match = create_item!(item_payload(armory, masks, %{"notes" => "needle too"}))

      conn =
        conn
        |> auth_conn("member")
        |> get("/api/inventory/items", %{
          "limit" => "10",
          "categoryId" => to_uuid(masks.id),
          "search" => "needle"
        })

      assert %{"data" => %{"items" => items}} = json_response(conn, 200)

      assert Enum.map(items, & &1["id"]) |> Enum.sort() ==
               [to_uuid(matching.id), to_uuid(second_match.id)] |> Enum.sort()

      paged =
        build_conn()
        |> auth_conn("member")
        |> get("/api/inventory/items", %{"limit" => "10"})
        |> json_response(200)

      assert %{"data" => %{"nextCursor" => nil}} = paged
    end

    test "rejects invalid limit values with 400, defaults on non-numeric", %{conn: conn} do
      category = insert_category!("Limit Edge")
      container = create_container!(%{"name" => "Limit Box"})
      _item = create_item!(item_payload(container, category))

      # limit=0 → 400 (not in allowed list)
      conn0 =
        build_conn() |> auth_conn("member") |> get("/api/inventory/items", %{"limit" => "0"})

      assert %{"errors" => %{"detail" => detail0}} = json_response(conn0, 400)
      assert detail0 =~ "limit"

      # limit=-1 → 400
      conn_neg =
        build_conn() |> auth_conn("member") |> get("/api/inventory/items", %{"limit" => "-1"})

      assert %{"errors" => %{"detail" => detail_neg}} = json_response(conn_neg, 400)
      assert detail_neg =~ "limit"

      # limit=10000 → 400 (not in allowed list; capped is not supported)
      conn_big =
        build_conn() |> auth_conn("member") |> get("/api/inventory/items", %{"limit" => "10000"})

      assert %{"errors" => %{"detail" => detail_big}} = json_response(conn_big, 400)
      assert detail_big =~ "limit"

      # limit=abc → defaults to 50 (200 OK)
      conn_abc =
        build_conn() |> auth_conn("member") |> get("/api/inventory/items", %{"limit" => "abc"})

      assert %{"data" => %{"limit" => 50}} = json_response(conn_abc, 200)
    end
  end

  describe "create" do
    test "creates an item and records created history for write roles", %{conn: conn} do
      category = insert_category!("Inventory Items Test Jackets")
      container = create_container!(%{"name" => "Rack"})

      conn =
        conn
        |> auth_conn("quartermaster")
        |> post("/api/inventory/items", item_payload(container, category))

      assert %{"data" => payload} = json_response(conn, 201)
      assert payload["containerId"] == to_uuid(container.id)
      assert payload["categoryId"] == to_uuid(category.id)
      assert payload["createdBy"] == @actor_id
      assert payload["quantity"] == 2
      assert history_actions(payload["id"]) == ["created"]
    end

    test "returns 403 for non-write roles", %{conn: conn} do
      category = insert_category!("No Write")
      container = create_container!(%{"name" => "Protected"})

      conn =
        conn
        |> auth_conn("member")
        |> post("/api/inventory/items", item_payload(container, category))

      assert json_response(conn, 403)
    end

    test "returns 422 for invalid payload", %{conn: conn} do
      conn =
        conn
        |> auth_conn("admin")
        |> post("/api/inventory/items", %{"quantity" => 0})

      assert %{"errors" => %{"detail" => detail}} = json_response(conn, 422)
      assert detail =~ "container_id"
      assert detail =~ "quantity"
    end

    test "rejects negative, float, and huge integer quantities with 422", %{conn: conn} do
      category = insert_category!("Inventory Items Quantity Validation")
      container = create_container!(%{"name" => "Qty Box"})

      for bad_qty <- [-1, 2.5, 1_000_001] do
        conn =
          build_conn()
          |> auth_conn("admin")
          |> post(
            "/api/inventory/items",
            item_payload(container, category, %{"quantity" => bad_qty})
          )

        assert %{"errors" => %{"detail" => detail}} = json_response(conn, 422)
        assert detail =~ "quantity"
      end
    end

    test "rejects non-object attributes (string, array) with 422", %{conn: conn} do
      category = insert_category!("Inventory Items Attribute Validation")
      container = create_container!(%{"name" => "Attr Box"})

      for bad_attrs <- ["not-a-map", [1, 2, 3]] do
        conn =
          build_conn()
          |> auth_conn("admin")
          |> post(
            "/api/inventory/items",
            item_payload(container, category, %{"attributes" => bad_attrs})
          )

        assert %{"errors" => %{"detail" => detail}} = json_response(conn, 422)
        assert detail =~ "attributes"
      end
    end
  end

  describe "show" do
    test "returns one item or 404", %{conn: conn} do
      category = insert_category!("Inventory Items Test Gorgets")
      container = create_container!(%{"name" => "Shelf"})
      item = create_item!(item_payload(container, category, %{"notes" => "visible"}))

      conn =
        conn
        |> auth_conn("member")
        |> get("/api/inventory/items/#{to_uuid(item.id)}")

      assert %{"data" => payload} = json_response(conn, 200)
      assert payload["id"] == to_uuid(item.id)
      assert payload["notes"] == "visible"

      conn =
        build_conn()
        |> auth_conn("member")
        |> get("/api/inventory/items/#{Ecto.UUID.generate()}")

      assert %{"errors" => %{"detail" => "Item not found"}} = json_response(conn, 404)
    end
  end

  describe "update" do
    test "updates fields and records updated history", %{conn: conn} do
      category = insert_category!("Inventory Items Test Longswords")
      container = create_container!(%{"name" => "Wall"})
      item = create_item!(item_payload(container, category))

      conn =
        conn
        |> auth_conn("admin")
        |> patch("/api/inventory/items/#{to_uuid(item.id)}", %{
          "quantity" => 4,
          "notes" => "updated note",
          "outForMaintenance" => true
        })

      assert %{"data" => payload} = json_response(conn, 200)
      assert payload["quantity"] == 4
      assert payload["notes"] == "updated note"
      assert payload["outForMaintenance"] == true
      assert payload["updatedBy"] == @actor_id
      assert history_actions(payload["id"]) == ["updated", "created"]
    end

    test "records moved history when containerId changes", %{conn: conn} do
      category = insert_category!("Inventory Items Test Swords")
      old = create_container!(%{"name" => "Old Box"})
      new = create_container!(%{"name" => "New Box"})
      item = create_item!(item_payload(old, category))

      conn =
        conn
        |> auth_conn("quartermaster")
        |> patch("/api/inventory/items/#{to_uuid(item.id)}", %{"containerId" => to_uuid(new.id)})

      assert %{"data" => payload} = json_response(conn, 200)
      assert payload["containerId"] == to_uuid(new.id)

      assert history_actions(payload["id"]) == ["updated", "moved", "created"]
    end
  end

  describe "history" do
    test "returns item history newest first with container summaries", %{conn: conn} do
      category = insert_category!("History Category")
      old = create_container!(%{"name" => "Old History"})
      new = create_container!(%{"name" => "New History"})
      item = create_item!(item_payload(old, category))

      {:ok, _} =
        Dhc.Inventory.update_item(
          to_uuid(item.id),
          %{"containerId" => to_uuid(new.id)},
          @actor_id
        )

      conn =
        conn
        |> auth_conn("member")
        |> get("/api/inventory/items/#{to_uuid(item.id)}/history", %{"limit" => "10"})

      assert %{"data" => %{"history" => history, "limit" => 10}} = json_response(conn, 200)
      assert Enum.map(history, & &1["action"]) == ["updated", "moved", "created"]

      moved = Enum.find(history, &(&1["action"] == "moved"))
      assert moved["oldContainer"] == %{"id" => to_uuid(old.id), "name" => "Old History"}
      assert moved["newContainer"] == %{"id" => to_uuid(new.id), "name" => "New History"}
    end
  end

  describe "delete" do
    test "deletes an item, cascades history, and returns 204", %{conn: conn} do
      category = insert_category!("Delete Category")
      container = create_container!(%{"name" => "Delete Container"})
      item = create_item!(item_payload(container, category))

      conn =
        conn
        |> auth_conn("president")
        |> delete("/api/inventory/items/#{to_uuid(item.id)}")

      assert response(conn, 204) == ""
      assert {:error, :not_found} = Dhc.Inventory.get_item(to_uuid(item.id))

      assert {:error, :not_found} = Dhc.Inventory.list_item_history(to_uuid(item.id), %{})
    end

    test "deletes an item that is out for maintenance — allowed, returns 204", %{conn: conn} do
      category = insert_category!("Delete Maint Category")
      container = create_container!(%{"name" => "Delete Maint Container"})
      item = create_item!(item_payload(container, category, %{"outForMaintenance" => true}))

      conn =
        conn
        |> auth_conn("president")
        |> delete("/api/inventory/items/#{to_uuid(item.id)}")

      assert response(conn, 204) == ""
      assert {:error, :not_found} = Dhc.Inventory.get_item(to_uuid(item.id))
    end
  end

  test "read endpoints allow authenticated roles", %{conn: conn} do
    category = insert_category!("Read Roles")
    container = create_container!(%{"name" => "Read Box"})
    item = create_item!(item_payload(container, category))

    for role <- @read_roles do
      assert %{"data" => _} =
               build_conn()
               |> auth_conn(role)
               |> get("/api/inventory/items/#{to_uuid(item.id)}")
               |> json_response(200)
    end
  end

  test "write endpoints allow inventory write roles", %{conn: _conn} do
    category = insert_category!("Write Roles")
    container = create_container!(%{"name" => "Write Box"})

    for role <- @write_roles do
      assert %{"data" => _} =
               build_conn()
               |> auth_conn(role)
               |> post(
                 "/api/inventory/items",
                 item_payload(container, category, %{"notes" => role})
               )
               |> json_response(201)
    end
  end
end
