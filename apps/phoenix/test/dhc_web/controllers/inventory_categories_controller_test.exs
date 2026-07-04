defmodule DhcWeb.InventoryCategoriesControllerTest do
  @moduledoc """
  Request/contract tests for the Equipment Category (Inventory Category) slice —
  ALE-105.

  Covers the ALE-104 contract for `GET/POST /inventory/categories` and
  `GET/PATCH/DELETE /inventory/categories/:id`: RBAC (member reads,
  inventory write roles), 404/409/422 error mapping, camelCase payload shape
  (`availableAttributes`, `itemCount`, `createdAt`), and the
  still-referenced-vs-empty delete semantics. The underlying domain logic is
  covered by `Dhc.InventoryTest`.
  """

  use DhcWeb.ConnCase, async: false

  import Ecto.Query

  alias Dhc.Repo

  # Inventory write roles — mirrors the `:inventory_admin_api` pipeline and the
  # existing SvelteKit `INVENTORY_ROLES`.
  @write_roles ~w(quartermaster admin president)
  # Reads are any authenticated member.
  @read_roles ~w(member quartermaster admin president)

  defmodule Verifier do
    for role <- ~w(quartermaster admin president member) do
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

  defp to_uuid(<<_::128>> = value), do: Ecto.UUID.load!(value)
  defp to_uuid(value) when is_binary(value), do: value

  # Insert a category directly, bypassing the API. Uses the Ecto schema so the
  # `:binary_id` PK and timestamps are wired correctly.
  defp insert_category(attrs) do
    attrs = Enum.into(attrs, %{})

    {:ok, category} =
      %Dhc.Inventory.EquipmentCategory{}
      |> Ecto.Changeset.cast(attrs, [:name, :description, :available_attributes])
      |> Ecto.Changeset.validate_required([:name])
      |> Repo.insert()

    category
  end

  # ── Index / list ──────────────────────────────────────────────────────

  describe "index" do
    test "returns categories ordered by name with itemCount", %{conn: conn} do
      insert_category(name: "Zzz Last", description: "last")
      insert_category(name: "Aaa First", available_attributes: [])

      conn =
        conn
        |> auth_conn("member")
        |> get("/api/inventory/categories")

      assert %{"data" => %{"categories" => categories}} = json_response(conn, 200)

      names = Enum.map(categories, & &1["name"])
      assert ^names = Enum.sort(names)

      # A category with no items reports itemCount 0.
      aaa = Enum.find(categories, &(&1["name"] == "Aaa First"))
      assert aaa["itemCount"] == 0
      assert aaa["description"] == nil
      assert aaa["availableAttributes"] == []
      # camelCase contracts
      assert Map.has_key?(aaa, "createdAt")
      assert Map.has_key?(aaa, "updatedAt")
      assert is_binary(aaa["id"])
    end

    test "allows any authenticated member role to read", %{conn: _conn} do
      for role <- @read_roles do
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
  end

  # ── Show ──────────────────────────────────────────────────────────────

  describe "show" do
    test "returns a single category by id", %{conn: conn} do
      # Use a non-seeded name to avoid colliding with the migration's default
      # categories (Masks, Gorgets, …).
      category = insert_category(name: "Slice Helmets", description: "Protective masks")

      conn =
        conn
        |> auth_conn("member")
        |> get("/api/inventory/categories/#{to_uuid(category.id)}")

      assert %{"data" => payload} = json_response(conn, 200)
      assert payload["id"] == to_uuid(category.id)
      assert payload["name"] == "Slice Helmets"
      assert payload["itemCount"] == 0
    end

    test "returns 404 for an unknown id", %{conn: conn} do
      conn =
        conn
        |> auth_conn("member")
        |> get("/api/inventory/categories/#{Ecto.UUID.generate()}")

      assert %{"errors" => %{"detail" => "Category not found"}} = json_response(conn, 404)
    end

    test "returns 401 without a bearer token", %{conn: conn} do
      conn = get(conn, "/api/inventory/categories/#{Ecto.UUID.generate()}")
      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end
  end

  # ── Create ────────────────────────────────────────────────────────────

  describe "create" do
    test "creates a category and returns 201 for write roles", %{conn: _conn} do
      for role <- @write_roles do
        conn =
          build_conn()
          |> auth_conn(role)
          |> post("/api/inventory/categories", %{
            "name" => "Test #{role}",
            "description" => "desc",
            "availableAttributes" => [
              %{"name" => "brand", "type" => "text", "label" => "Brand", "required" => true}
            ]
          })

        assert %{"data" => payload} = json_response(conn, 201)
        assert payload["name"] == "Test #{role}"
        assert payload["itemCount"] == 0
        assert [attr] = payload["availableAttributes"]
        assert attr["name"] == "brand"
      end
    end

    test "accepts either camelCase or snake_case availableAttributes", %{conn: conn} do
      conn =
        conn
        |> auth_conn("quartermaster")
        |> post("/api/inventory/categories", %{
          "name" => "Snake Case Category",
          "available_attributes" => [
            %{"name" => "size", "type" => "select", "options" => ["S", "M"]}
          ]
        })

      assert %{"data" => payload} = json_response(conn, 201)
      assert length(payload["availableAttributes"]) == 1
    end

    test "returns 403 for non-write roles", %{conn: conn} do
      conn =
        conn
        |> auth_conn("member")
        |> post("/api/inventory/categories", %{"name" => "Blocked"})

      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
    end

    test "returns 401 without a bearer token", %{conn: conn} do
      conn = post(conn, "/api/inventory/categories", %{"name" => "Nope"})
      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "returns 409 when the name already exists", %{conn: conn} do
      insert_category(name: "Duplicate Name")

      conn =
        conn
        |> auth_conn("admin")
        |> post("/api/inventory/categories", %{
          "name" => "Duplicate Name",
          "availableAttributes" => []
        })

      assert %{"errors" => %{"detail" => "A category with that name already exists"}} =
               json_response(conn, 409)
    end

    test "returns 422 when name is missing", %{conn: conn} do
      conn =
        conn
        |> auth_conn("admin")
        |> post("/api/inventory/categories", %{"availableAttributes" => []})

      assert %{"errors" => %{"detail" => detail}} = json_response(conn, 422)
      assert detail =~ "name"
    end

    test "returns 422 when name is too long", %{conn: conn} do
      conn =
        conn
        |> auth_conn("admin")
        |> post("/api/inventory/categories", %{"name" => String.duplicate("x", 51)})

      assert %{"errors" => %{"detail" => _detail}} = json_response(conn, 422)
    end
  end

  # ── Update ────────────────────────────────────────────────────────────

  describe "update" do
    test "updates the category and returns 200 for write roles", %{conn: conn} do
      category = insert_category(name: "Old Name")

      conn =
        conn
        |> auth_conn("quartermaster")
        |> patch("/api/inventory/categories/#{to_uuid(category.id)}", %{
          "name" => "New Name",
          "description" => "updated desc"
        })

      assert %{"data" => payload} = json_response(conn, 200)
      assert payload["name"] == "New Name"
      assert payload["description"] == "updated desc"
    end

    test "returns 404 for an unknown id", %{conn: conn} do
      conn =
        conn
        |> auth_conn("admin")
        |> patch("/api/inventory/categories/#{Ecto.UUID.generate()}", %{"name" => "X"})

      assert %{"errors" => %{"detail" => "Category not found"}} = json_response(conn, 404)
    end

    test "returns 409 when renaming to an existing name", %{conn: conn} do
      insert_category(name: "Taken")
      category = insert_category(name: "Mine")

      conn =
        conn
        |> auth_conn("admin")
        |> patch("/api/inventory/categories/#{to_uuid(category.id)}", %{"name" => "Taken"})

      assert %{"errors" => %{"detail" => "A category with that name already exists"}} =
               json_response(conn, 409)
    end

    test "returns 403 for non-write roles", %{conn: conn} do
      category = insert_category(name: "To Update")

      conn =
        conn
        |> auth_conn("member")
        |> patch("/api/inventory/categories/#{to_uuid(category.id)}", %{"name" => "Blocked"})

      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
    end
  end

  # ── Delete ────────────────────────────────────────────────────────────

  describe "delete" do
    test "deletes an unreferenced category and returns 204", %{conn: conn} do
      category = insert_category(name: "Delete Me")

      conn =
        conn
        |> auth_conn("admin")
        |> delete("/api/inventory/categories/#{to_uuid(category.id)}")

      assert conn.status == 204
      assert conn.resp_body == ""

      # Gone from the list.
      list_conn =
        build_conn()
        |> auth_conn("member")
        |> get("/api/inventory/categories")

      names =
        list_conn
        |> json_response(200)
        |> get_in(["data", "categories"])
        |> Enum.map(& &1["name"])

      refute "Delete Me" in names
    end

    test "returns 404 for an unknown id", %{conn: conn} do
      conn =
        conn
        |> auth_conn("admin")
        |> delete("/api/inventory/categories/#{Ecto.UUID.generate()}")

      assert %{"errors" => %{"detail" => "Category not found"}} = json_response(conn, 404)
    end

    test "returns 409 when items still reference the category", %{conn: conn} do
      category = insert_category(name: "Referenced")
      container_id = insert_container!()

      # Insert an item pointing at the category directly. `inventory_items`
      # FKs are on_delete: :nothing; the delete guard must surface them as 409.
      {:ok, _} =
        Repo.query(
          """
          INSERT INTO inventory_items
            (id, container_id, category_id, attributes, quantity, created_at, updated_at)
          VALUES ($1, $2, $3, '{}'::jsonb, 1, NOW(), NOW())
          """,
          # uuid columns require 16-byte binaries for raw SQL params.
          [
            Ecto.UUID.dump!(Ecto.UUID.generate()),
            Ecto.UUID.dump!(container_id),
            Ecto.UUID.dump!(to_uuid(category.id))
          ]
        )

      conn =
        conn
        |> auth_conn("admin")
        |> delete("/api/inventory/categories/#{to_uuid(category.id)}")

      assert %{"errors" => %{"detail" => "Category is still referenced by inventory items"}} =
               json_response(conn, 409)

      # Still exists.
      assert Repo.aggregate(
               from(c in Dhc.Inventory.EquipmentCategory, where: c.name == "Referenced"),
               :count
             ) == 1
    end

    test "returns 403 for non-write roles", %{conn: conn} do
      category = insert_category(name: "Protected")

      conn =
        conn
        |> auth_conn("member")
        |> delete("/api/inventory/categories/#{to_uuid(category.id)}")

      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
    end
  end

  # Insert a container row with a synthetic `created_by` user so the FK is
  # satisfied without standing up a full user profile. Returns the container id
  # as a string UUID.
  defp insert_container! do
    user_id = Ecto.UUID.generate()

    {:ok, _} =
      Repo.query(
        "INSERT INTO auth.users (id, aud, role, email) VALUES ($1, 'authenticated', 'authenticated', $2)",
        [Ecto.UUID.dump!(user_id), "inv-#{System.unique_integer([:positive])}@example.com"]
      )

    container_id = Ecto.UUID.generate()

    {:ok, _} =
      Repo.query(
        """
        INSERT INTO containers (id, name, created_by, created_at, updated_at)
        VALUES ($1, $2, $3, NOW(), NOW())
        """,
        [Ecto.UUID.dump!(container_id), "Test Container", Ecto.UUID.dump!(user_id)]
      )

    container_id
  end
end
