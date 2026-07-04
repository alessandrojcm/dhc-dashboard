defmodule DhcWeb.InventoryItemsMovementControllerTest do
  @moduledoc """
  Request/contract tests for the dedicated movement and maintenance command
  endpoints — ALE-108.

  Covers the ALE-104 contract for `POST /inventory/items/:id/move` and
  `POST /inventory/items/:id/maintenance`: RBAC (inventory write roles only),
  camelCase payload shape, `moved` / `maintenance_out` / `maintenance_in`
  history side effects, 404/422 error mapping, and that the dedicated commands
  leave the rest of the item's fields untouched.
  """

  use DhcWeb.ConnCase, async: false

  alias Dhc.Repo

  @actor_id "11111111-1111-1111-1111-111111111111"
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

    insert_user!(@actor_id, "inv-movement-actor@example.com")

    on_exit(fn -> Application.put_env(:dhc, :auth_verifier, original) end)

    :ok
  end

  defp auth_conn(conn, role), do: put_req_header(conn, "authorization", "Bearer #{role}-token")

  defp to_uuid(<<_::128>> = value), do: Ecto.UUID.load!(value)
  defp to_uuid(value) when is_binary(value), do: value

  defp insert_user!(id, email) do
    {:ok, _} =
      Repo.query(
        "INSERT INTO auth.users (id, aud, role, email) VALUES ($1, 'authenticated', 'authenticated', $2)",
        [Ecto.UUID.dump!(id), email]
      )

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

  defp item_payload(container, category, overrides \\ %{}) do
    Map.merge(
      %{
        "containerId" => to_uuid(container.id),
        "categoryId" => to_uuid(category.id),
        "quantity" => 2,
        "attributes" => %{"brand" => "PBT", "name" => "Longsword"},
        "notes" => "Test item",
        "outForMaintenance" => false
      },
      overrides
    )
  end

  defp history_actions(item_id) do
    {:ok, history} = Dhc.Inventory.list_item_history(to_uuid(item_id), %{"limit" => "20"})
    Enum.map(history, &Atom.to_string(&1.action))
  end

  describe "move" do
    test "moves the item and records moved history for write roles", %{conn: conn} do
      category = insert_category!("ALE108 Helmets")
      old = create_container!(%{"name" => "Old Move Box"})
      new = create_container!(%{"name" => "New Move Box"})
      item = create_item!(item_payload(old, category))

      conn =
        conn
        |> auth_conn("quartermaster")
        |> post("/api/inventory/items/#{to_uuid(item.id)}/move", %{
          "containerId" => to_uuid(new.id),
          "notes" => "Relocated for repair"
        })

      assert %{"data" => payload} = json_response(conn, 200)
      assert payload["containerId"] == to_uuid(new.id)
      assert payload["updatedBy"] == @actor_id
      # Other fields are left untouched by the dedicated move command.
      assert payload["quantity"] == 2
      assert payload["outForMaintenance"] == false

      assert history_actions(payload["id"]) == ["moved", "created"]

      {:ok, history} = Dhc.Inventory.list_item_history(to_uuid(payload["id"]), %{"limit" => "20"})
      moved = Enum.find(history, &(&1.action == :moved))
      assert moved.old_container_id == to_uuid(old.id)
      assert moved.new_container_id == to_uuid(new.id)
      assert moved.notes == "Relocated for repair"
    end

    test "returns 404 for unknown item", %{conn: conn} do
      category = insert_category!("ALE108 Missing")
      new = create_container!(%{"name" => "Target Box"})

      conn =
        conn
        |> auth_conn("admin")
        |> post("/api/inventory/items/#{Ecto.UUID.generate()}/move", %{
          "containerId" => to_uuid(new.id)
        })

      assert %{"errors" => %{"detail" => "Item not found"}} = json_response(conn, 404)
    end

    test "returns 422 for unknown container", %{conn: conn} do
      category = insert_category!("ALE108 Bad Target")
      old = create_container!(%{"name" => "Source Box"})
      item = create_item!(item_payload(old, category))

      conn =
        conn
        |> auth_conn("admin")
        |> post("/api/inventory/items/#{to_uuid(item.id)}/move", %{
          "containerId" => Ecto.UUID.generate()
        })

      assert %{"errors" => %{"detail" => detail}} = json_response(conn, 422)
      assert detail =~ "container_id"
    end

    test "returns 422 when containerId is missing", %{conn: conn} do
      category = insert_category!("ALE108 No Container")
      old = create_container!(%{"name" => "Holding Box"})
      item = create_item!(item_payload(old, category))

      conn =
        conn
        |> auth_conn("admin")
        |> post("/api/inventory/items/#{to_uuid(item.id)}/move", %{"notes" => "where to?"})

      assert %{"errors" => %{"detail" => detail}} = json_response(conn, 422)
      assert detail =~ "container_id"
    end

    test "returns 403 for non-write roles", %{conn: conn} do
      category = insert_category!("ALE108 Protected Move")
      old = create_container!(%{"name" => "Old"})
      new = create_container!(%{"name" => "New"})
      item = create_item!(item_payload(old, category))

      conn =
        conn
        |> auth_conn("member")
        |> post("/api/inventory/items/#{to_uuid(item.id)}/move", %{
          "containerId" => to_uuid(new.id)
        })

      assert json_response(conn, 403)
    end
  end

  describe "maintenance" do
    test "flags maintenance out and records maintenance_out history", %{conn: conn} do
      category = insert_category!("ALE108 Gauntlets")
      container = create_container!(%{"name" => "Workshop"})
      item = create_item!(item_payload(container, category))

      conn =
        conn
        |> auth_conn("quartermaster")
        |> post("/api/inventory/items/#{to_uuid(item.id)}/maintenance", %{
          "outForMaintenance" => true,
          "notes" => "Strap broken"
        })

      assert %{"data" => payload} = json_response(conn, 200)
      assert payload["outForMaintenance"] == true
      assert payload["updatedBy"] == @actor_id
      # Other fields untouched.
      assert payload["quantity"] == 2
      assert payload["containerId"] == to_uuid(container.id)

      assert history_actions(payload["id"]) == ["maintenance_out", "created"]

      {:ok, history} = Dhc.Inventory.list_item_history(to_uuid(payload["id"]), %{"limit" => "20"})
      out_row = Enum.find(history, &(&1.action == :maintenance_out))
      assert out_row.notes == "Strap broken"
      # Maintenance rows carry no container change.
      assert out_row.old_container_id == nil
      assert out_row.new_container_id == nil
    end

    test "returns an item from maintenance and records maintenance_in history", %{conn: conn} do
      category = insert_category!("ALE108 Returns")
      container = create_container!(%{"name" => "Rack"})
      item = create_item!(item_payload(container, category, %{"outForMaintenance" => true}))

      conn =
        conn
        |> auth_conn("admin")
        |> post("/api/inventory/items/#{to_uuid(item.id)}/maintenance", %{
          "outForMaintenance" => false
        })

      assert %{"data" => payload} = json_response(conn, 200)
      assert payload["outForMaintenance"] == false
      assert history_actions(payload["id"]) == ["maintenance_in", "created"]
    end

    test "returns 422 when outForMaintenance is missing", %{conn: conn} do
      category = insert_category!("ALE108 No Flag")
      container = create_container!(%{"name" => "Box"})
      item = create_item!(item_payload(container, category))

      conn =
        conn
        |> auth_conn("admin")
        |> post("/api/inventory/items/#{to_uuid(item.id)}/maintenance", %{"notes" => "???"})

      assert %{"errors" => %{"detail" => detail}} = json_response(conn, 422)
      assert detail =~ "out_for_maintenance"
    end

    test "returns 422 when outForMaintenance is not a boolean", %{conn: conn} do
      category = insert_category!("ALE108 Bad Flag")
      container = create_container!(%{"name" => "Box"})
      item = create_item!(item_payload(container, category))

      conn =
        conn
        |> auth_conn("admin")
        |> post("/api/inventory/items/#{to_uuid(item.id)}/maintenance", %{
          "outForMaintenance" => "yes"
        })

      assert %{"errors" => %{"detail" => detail}} = json_response(conn, 422)
      assert detail =~ "out_for_maintenance"
    end

    test "returns 404 for unknown item", %{conn: conn} do
      conn =
        conn
        |> auth_conn("admin")
        |> post("/api/inventory/items/#{Ecto.UUID.generate()}/maintenance", %{
          "outForMaintenance" => true
        })

      assert %{"errors" => %{"detail" => "Item not found"}} = json_response(conn, 404)
    end

    test "returns 403 for non-write roles", %{conn: conn} do
      category = insert_category!("ALE108 Protected Maint")
      container = create_container!(%{"name" => "Box"})
      item = create_item!(item_payload(container, category))

      conn =
        conn
        |> auth_conn("member")
        |> post("/api/inventory/items/#{to_uuid(item.id)}/maintenance", %{
          "outForMaintenance" => true
        })

      assert json_response(conn, 403)
    end
  end

  test "move/maintenance allow inventory write roles", %{conn: _conn} do
    category = insert_category!("ALE108 Write Roles Move")
    old = create_container!(%{"name" => "Old Box"})
    new = create_container!(%{"name" => "New Box"})

    for role <- @write_roles do
      item = create_item!(item_payload(old, category, %{"notes" => role}))

      assert %{"data" => _} =
               build_conn()
               |> auth_conn(role)
               |> post("/api/inventory/items/#{to_uuid(item.id)}/move", %{
                 "containerId" => to_uuid(new.id)
               })
               |> json_response(200)

      assert %{"data" => _} =
               build_conn()
               |> auth_conn(role)
               |> post("/api/inventory/items/#{to_uuid(item.id)}/maintenance", %{
                 "outForMaintenance" => true
               })
               |> json_response(200)
    end
  end
end
