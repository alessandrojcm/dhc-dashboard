defmodule DhcWeb.InventoryContainersControllerTest do
  @moduledoc """
  Request/contract tests for the Inventory Container slice — ALE-106.

  Covers the ALE-104 contract for `GET/POST /inventory/containers` and
  `GET/PATCH/DELETE /inventory/containers/:id`: RBAC (member reads,
  inventory write roles), 404/409/422 error mapping, camelCase payload shape
  (`parentContainerId`, `parentContainer`, `childContainers`, `itemCount`,
  `outForMaintenance`), hierarchy/parent-summary semantics, circular-parent
  prevention, and the still-contains-items delete conflict. The underlying
  domain logic is covered by `Dhc.InventoryTest`.
  """

  use DhcWeb.ConnCase, async: false

  alias Dhc.Repo

  # A fixed Supabase user id the test Verifier always returns as `sub`. We
  # insert a matching `auth.users` row in `setup` so the NOT-NULL
  # `containers.created_by` FK is satisfied for `create_container`.
  @actor_id "11111111-1111-1111-1111-111111111111"

  # Inventory write roles — mirrors the `:inventory_admin_api` pipeline and the
  # existing SvelteKit `INVENTORY_ROLES`.
  @write_roles ~w(quartermaster admin president)
  # Reads are any authenticated member.
  @read_roles ~w(member quartermaster admin president)

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

    # Stand up the auth.users row the JWT `sub` resolves to. All roles share
    # the same synthetic user; RBAC is about the JWT role list, not the user.
    insert_user!(@actor_id, "inv-actor@example.com")

    on_exit(fn -> Application.put_env(:dhc, :auth_verifier, original) end)

    :ok
  end

  defp auth_conn(conn, role), do: put_req_header(conn, "authorization", "Bearer #{role}-token")

  defp to_uuid(<<_::128>> = value), do: Ecto.UUID.load!(value)
  defp to_uuid(value) when is_binary(value), do: value

  # Insert the synthetic auth.users row backing `@actor_id`.
  defp insert_user!(id, email) do
    {:ok, _} =
      Dhc.Auth.register_principal_with_id(id, %{email: email})

    :ok
  end

  # Create a container through the context (sets `created_by` correctly and
  # returns the populated struct). Accepts the camelCase contract shape.
  defp create_container!(attrs) do
    {:ok, container} = Dhc.Inventory.create_container(attrs, @actor_id)
    container
  end

  # Insert an `inventory_items` row directly pointing at a container/category.
  # Container FK is `on_delete: :nothing`; this is the delete-conflict setup.
  defp insert_item!(container_id, category_id) do
    {:ok, _} =
      Repo.query(
        """
        INSERT INTO inventory_items
          (id, container_id, category_id, attributes, quantity, created_at, updated_at)
        VALUES ($1, $2, $3, '{}'::jsonb, 1, NOW(), NOW())
        """,
        [
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          Ecto.UUID.dump!(container_id),
          Ecto.UUID.dump!(category_id)
        ]
      )

    :ok
  end

  defp insert_category!(name) do
    {:ok, category} =
      %Dhc.Inventory.EquipmentCategory{}
      |> Ecto.Changeset.cast(%{name: name}, [:name])
      |> Ecto.Changeset.validate_required([:name])
      |> Repo.insert()

    category
  end

  # ── Index / list ──────────────────────────────────────────────────────

  describe "index" do
    test "returns flat containers ordered by name with itemCount and parentContainer", %{
      conn: conn
    } do
      root = create_container!(%{"name" => "Root Room", "description" => "main"})
      # A nested container; sorted after Root Room alphabetically? Zzz > Root.
      child = create_container!(%{"name" => "Zzz Nested", "parentContainerId" => root.id})
      # Empty/root level container with no parent.
      create_container!(%{"name" => "Aaa First"})

      conn =
        conn
        |> auth_conn("member")
        |> get("/api/inventory/containers")

      assert %{"data" => %{"containers" => containers}} = json_response(conn, 200)

      names = Enum.map(containers, & &1["name"])
      assert ^names = Enum.sort(names)

      # Root room: parentContainer nil, parentContainerId nil, itemCount 0.
      root_payload = Enum.find(containers, &(&1["name"] == "Root Room"))

      assert root_payload["parentContainerId"] == to_uuid(root.id) or
               root_payload["parentContainerId"] == nil

      # parentContainerId is nil for a root container this test created with no parent.
      assert root_payload["parentContainer"] == nil
      assert root_payload["itemCount"] == 0
      assert Map.has_key?(root_payload, "id")
      assert Map.has_key?(root_payload, "createdAt")
      assert Map.has_key?(root_payload, "updatedAt")

      # Nested container carries the parent summary.
      nested = Enum.find(containers, &(&1["name"] == "Zzz Nested"))
      assert nested["parentContainerId"] == to_uuid(child.parent_container_id)
      assert nested["parentContainer"] == %{"id" => to_uuid(root.id), "name" => "Root Room"}
    end

    test "itemCount reflects direct items only", %{conn: conn} do
      container = create_container!(%{"name" => "Box"})
      category = insert_category!("Box Cat")
      insert_item!(container.id, category.id)

      conn =
        conn
        |> auth_conn("member")
        |> get("/api/inventory/containers")

      [box] =
        json_response(conn, 200)
        |> get_in(["data", "containers"])
        |> Enum.filter(&(&1["name"] == "Box"))

      assert box["itemCount"] == 1
    end

    test "allows any authenticated member role to read", %{conn: _conn} do
      for role <- @read_roles do
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

    test "returns 401 with an invalid token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer bad-token")
        |> get("/api/inventory/containers")

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end
  end

  # ── Show / detail ──────────────────────────────────────────────────────

  describe "show" do
    test "returns detail with parentContainer, childContainers, and items", %{conn: conn} do
      parent = create_container!(%{"name" => "Parent"})
      container = create_container!(%{"name" => "Child", "parentContainerId" => parent.id})
      # A grandchild container is NOT a child of `container`; only direct ones are.
      create_container!(%{"name" => "Grandchild", "parentContainerId" => container.id})
      category = insert_category!("Detail Cat")
      insert_item!(container.id, category.id)

      conn =
        conn
        |> auth_conn("member")
        |> get("/api/inventory/containers/#{to_uuid(container.id)}")

      assert %{"data" => payload} = json_response(conn, 200)
      assert payload["id"] == to_uuid(container.id)
      assert payload["name"] == "Child"
      assert payload["parentContainer"] == %{"id" => to_uuid(parent.id), "name" => "Parent"}
      assert payload["itemCount"] == 1

      [child_container] = payload["childContainers"]
      assert child_container["name"] == "Grandchild"

      [item] = payload["items"]
      assert item["category"]["name"] == "Detail Cat"
      assert item["quantity"] == 1
      assert item["outForMaintenance"] == false
    end

    test "returns childContainers as empty for a leaf container", %{conn: conn} do
      container = create_container!(%{"name" => "Leaf"})

      conn =
        conn
        |> auth_conn("member")
        |> get("/api/inventory/containers/#{to_uuid(container.id)}")

      assert %{"data" => payload} = json_response(conn, 200)
      assert payload["childContainers"] == []
      assert payload["items"] == []
      assert payload["itemCount"] == 0
    end

    test "returns 404 for an unknown id", %{conn: conn} do
      conn =
        conn
        |> auth_conn("member")
        |> get("/api/inventory/containers/#{Ecto.UUID.generate()}")

      assert %{"errors" => %{"detail" => "Container not found"}} = json_response(conn, 404)
    end

    test "returns 401 without a bearer token", %{conn: conn} do
      conn = get(conn, "/api/inventory/containers/#{Ecto.UUID.generate()}")
      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end
  end

  # ── Create ────────────────────────────────────────────────────────────

  describe "create" do
    test "creates a container and returns 201 for write roles", %{conn: _conn} do
      for role <- @write_roles do
        conn =
          build_conn()
          |> auth_conn(role)
          |> post("/api/inventory/containers", %{
            "name" => "Test #{role}",
            "description" => "desc"
          })

        assert %{"data" => payload} = json_response(conn, 201)
        assert payload["name"] == "Test #{role}"
        assert payload["description"] == "desc"
        assert payload["itemCount"] == 0
        assert payload["parentContainerId"] == nil
        assert payload["parentContainer"] == nil
        assert is_binary(payload["id"])
      end
    end

    test "accepts parentContainerId and reflects parentContainer summary", %{conn: conn} do
      parent = create_container!(%{"name" => "Parent Create"})

      conn =
        conn
        |> auth_conn("quartermaster")
        |> post("/api/inventory/containers", %{
          "name" => "Nested",
          "parentContainerId" => parent.id
        })

      assert %{"data" => payload} = json_response(conn, 201)
      assert payload["parentContainerId"] == to_uuid(parent.id)

      assert payload["parentContainer"] == %{
               "id" => to_uuid(parent.id),
               "name" => "Parent Create"
             }
    end

    test "accepts snake_case parent_container_id", %{conn: conn} do
      parent = create_container!(%{"name" => "Snake Parent"})

      conn =
        conn
        |> auth_conn("quartermaster")
        |> post("/api/inventory/containers", %{
          "name" => "Snake Child",
          "parent_container_id" => parent.id
        })

      assert %{"data" => payload} = json_response(conn, 201)
      assert payload["parentContainerId"] == to_uuid(parent.id)
    end

    test "returns 422 when name is missing", %{conn: conn} do
      conn =
        conn
        |> auth_conn("admin")
        |> post("/api/inventory/containers", %{"description" => "no name"})

      assert %{"errors" => %{"detail" => detail}} = json_response(conn, 422)
      assert detail =~ "name"
    end

    test "returns 422 when name is too long", %{conn: conn} do
      conn =
        conn
        |> auth_conn("admin")
        |> post("/api/inventory/containers", %{"name" => String.duplicate("x", 101)})

      assert %{"errors" => %{"detail" => _detail}} = json_response(conn, 422)
    end

    test "returns 422 when parentContainerId refers to a missing container", %{conn: conn} do
      conn =
        conn
        |> auth_conn("admin")
        |> post("/api/inventory/containers", %{
          "name" => "Orphan",
          "parentContainerId" => Ecto.UUID.generate()
        })

      assert %{"errors" => %{"detail" => _detail}} = json_response(conn, 422)
    end

    test "returns 403 for non-write roles", %{conn: conn} do
      conn =
        conn
        |> auth_conn("member")
        |> post("/api/inventory/containers", %{"name" => "Blocked"})

      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
    end

    test "returns 401 without a bearer token", %{conn: conn} do
      conn = post(conn, "/api/inventory/containers", %{"name" => "Nope"})
      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end
  end

  # ── Update ────────────────────────────────────────────────────────────

  describe "update" do
    test "updates name and description and returns 200 for write roles", %{conn: conn} do
      container = create_container!(%{"name" => "Old Name", "description" => "old"})

      conn =
        conn
        |> auth_conn("quartermaster")
        |> patch("/api/inventory/containers/#{to_uuid(container.id)}", %{
          "name" => "New Name",
          "description" => "new desc"
        })

      assert %{"data" => payload} = json_response(conn, 200)
      assert payload["name"] == "New Name"
      assert payload["description"] == "new desc"
    end

    test "can re-parent to an existing container", %{conn: conn} do
      target = create_container!(%{"name" => "Target Parent"})
      container = create_container!(%{"name" => "Movable"})

      conn =
        conn
        |> auth_conn("admin")
        |> patch("/api/inventory/containers/#{to_uuid(container.id)}", %{
          "parentContainerId" => target.id
        })

      assert %{"data" => payload} = json_response(conn, 200)
      assert payload["parentContainerId"] == to_uuid(target.id)

      assert payload["parentContainer"] == %{
               "id" => to_uuid(target.id),
               "name" => "Target Parent"
             }
    end

    test "can detach to root via null parentContainerId", %{conn: conn} do
      parent = create_container!(%{"name" => "Detach Parent"})
      container = create_container!(%{"name" => "Nested", "parentContainerId" => parent.id})

      conn =
        conn
        |> auth_conn("admin")
        |> patch("/api/inventory/containers/#{to_uuid(container.id)}", %{
          "parentContainerId" => nil
        })

      assert %{"data" => payload} = json_response(conn, 200)
      assert payload["parentContainerId"] == nil
      assert payload["parentContainer"] == nil
    end

    test "omitting parentContainerId leaves the parent unchanged", %{conn: conn} do
      parent = create_container!(%{"name" => "Keep Parent"})
      container = create_container!(%{"name" => "Keep Me", "parentContainerId" => parent.id})

      conn =
        conn
        |> auth_conn("admin")
        |> patch("/api/inventory/containers/#{to_uuid(container.id)}", %{
          "name" => "Renamed Only"
        })

      assert %{"data" => payload} = json_response(conn, 200)
      assert payload["name"] == "Renamed Only"
      assert payload["parentContainerId"] == to_uuid(parent.id)
    end

    test "returns 404 for an unknown id", %{conn: conn} do
      conn =
        conn
        |> auth_conn("admin")
        |> patch("/api/inventory/containers/#{Ecto.UUID.generate()}", %{"name" => "X"})

      assert %{"errors" => %{"detail" => "Container not found"}} = json_response(conn, 404)
    end

    test "returns 422 when re-parenting to self", %{conn: conn} do
      container = create_container!(%{"name" => "Self"})

      conn =
        conn
        |> auth_conn("admin")
        |> patch("/api/inventory/containers/#{to_uuid(container.id)}", %{
          "parentContainerId" => container.id
        })

      assert %{"errors" => %{"detail" => detail}} = json_response(conn, 422)
      assert detail =~ "cycle"
    end

    test "returns 422 when re-parenting to a direct descendant", %{conn: conn} do
      parent = create_container!(%{"name" => "G"})
      child = create_container!(%{"name" => "C", "parentContainerId" => parent.id})
      grandchild = create_container!(%{"name" => "GC", "parentContainerId" => child.id})

      # Re-parenting grandparent (G) onto its grandchild (GC) would cycle.
      conn =
        conn
        |> auth_conn("admin")
        |> patch("/api/inventory/containers/#{to_uuid(parent.id)}", %{
          "parentContainerId" => grandchild.id
        })

      assert %{"errors" => %{"detail" => detail}} = json_response(conn, 422)
      assert detail =~ "cycle"

      # Unchanged in the DB.
      assert {:ok, fresh} = Dhc.Inventory.get_container(parent.id)
      assert fresh.parent_container_id == nil
    end

    test "returns 403 for non-write roles", %{conn: conn} do
      container = create_container!(%{"name" => "Protected"})

      conn =
        conn
        |> auth_conn("member")
        |> patch("/api/inventory/containers/#{to_uuid(container.id)}", %{"name" => "Blocked"})

      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
    end
  end

  # ── Delete ────────────────────────────────────────────────────────────

  describe "delete" do
    test "deletes an empty container and returns 204", %{conn: conn} do
      container = create_container!(%{"name" => "Delete Me"})

      conn =
        conn
        |> auth_conn("admin")
        |> delete("/api/inventory/containers/#{to_uuid(container.id)}")

      assert conn.status == 204
      assert conn.resp_body == ""

      # Gone from the list.
      names =
        build_conn()
        |> auth_conn("member")
        |> get("/api/inventory/containers")
        |> json_response(200)
        |> get_in(["data", "containers"])
        |> Enum.map(& &1["name"])

      refute "Delete Me" in names
    end

    test "cascades deletion to empty child containers", %{conn: conn} do
      parent = create_container!(%{"name" => "Cascade Parent"})
      create_container!(%{"name" => "Cascade Child", "parentContainerId" => parent.id})

      conn =
        conn
        |> auth_conn("admin")
        |> delete("/api/inventory/containers/#{to_uuid(parent.id)}")

      assert conn.status == 204

      names =
        build_conn()
        |> auth_conn("member")
        |> get("/api/inventory/containers")
        |> json_response(200)
        |> get_in(["data", "containers"])
        |> Enum.map(& &1["name"])

      refute "Cascade Parent" in names
      refute "Cascade Child" in names
    end

    test "returns 409 when the container still contains items", %{conn: conn} do
      container = create_container!(%{"name" => "Has Items"})
      category = insert_category!("Empty Cat")
      insert_item!(container.id, category.id)

      conn =
        conn
        |> auth_conn("admin")
        |> delete("/api/inventory/containers/#{to_uuid(container.id)}")

      assert %{"errors" => %{"detail" => "Container still contains inventory items"}} =
               json_response(conn, 409)

      # Still exists.
      assert {:ok, _} = Dhc.Inventory.get_container(container.id)
    end

    test "returns 404 for an unknown id", %{conn: conn} do
      conn =
        conn
        |> auth_conn("admin")
        |> delete("/api/inventory/containers/#{Ecto.UUID.generate()}")

      assert %{"errors" => %{"detail" => "Container not found"}} = json_response(conn, 404)
    end

    test "returns 403 for non-write roles", %{conn: conn} do
      container = create_container!(%{"name" => "Protected"})

      conn =
        conn
        |> auth_conn("member")
        |> delete("/api/inventory/containers/#{to_uuid(container.id)}")

      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
    end
  end
end
