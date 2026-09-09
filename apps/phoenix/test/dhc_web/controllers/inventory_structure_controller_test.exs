defmodule DhcWeb.InventoryStructureControllerTest do
  @moduledoc """
  Request/contract tests for ALE-292 (ALE-283c) operator structure viewers.

  Covers viewer-shaped OpenAPI for categories, definitions, options, and
  containers: camelCase projections, command-specific requests, role gates,
  and domain-error mapping (`type_immutable`, `required_blocked`,
  `still_referenced`, `not_single_select`, hierarchy conflicts). Domain
  gates live in `Dhc.Inventory.StructureDefinitionsTest` and
  `Dhc.Inventory.ContainerHierarchyTest`.
  """

  use DhcWeb.ConnCase, async: false

  alias Dhc.Inventory

  @actor_id "11111111-1111-1111-1111-111111111111"
  @write_roles ~w(quartermaster admin president)
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

    insert_principal!(@actor_id, "inv-structure-actor@example.com")

    on_exit(fn -> Application.put_env(:dhc, :auth_verifier, original) end)

    :ok
  end

  defp auth_conn(conn, role), do: put_req_header(conn, "authorization", "Bearer #{role}-token")

  defp to_uuid(<<_::128>> = value), do: Ecto.UUID.load!(value)
  defp to_uuid(value) when is_binary(value), do: value

  defp insert_principal!(id, email) do
    {:ok, _} = Dhc.Auth.register_principal_with_id(id, %{email: email})
    :ok
  end

  defp insert_category!(name \\ "Struct Cat #{System.unique_integer([:positive])}") do
    {:ok, category} = Inventory.create_category(%{"name" => name})
    category
  end

  # ── Definitions: list ───────────────────────────────────────────

  describe "definitions index" do
    test "returns definitions for a category with live options and identifying order", %{
      conn: conn
    } do
      category = insert_category!()

      assert {:ok, size} =
               Inventory.create_definition(category.id, %{
                 "label" => "Size",
                 "valueType" => "single_select",
                 "identifyingPosition" => 0
               })

      assert {:ok, note} =
               Inventory.create_definition(category.id, %{
                 "label" => "Note",
                 "valueType" => "text"
               })

      assert {:ok, option} = Inventory.create_option(size.id, %{"label" => "Large"})

      conn =
        conn
        |> auth_conn("member")
        |> get("/api/inventory/categories/#{to_uuid(category.id)}/definitions")

      assert %{"data" => %{"definitions" => definitions}} = json_response(conn, 200)
      assert [first, second] = definitions
      assert first["id"] == to_uuid(size.id)
      assert first["label"] == "Size"
      assert first["valueType"] == "single_select"
      assert first["required"] == false
      assert first["identifyingPosition"] == 0
      assert first["retiredAt"] == nil
      assert first["categoryId"] == to_uuid(category.id)
      assert [rendered] = first["options"]
      assert rendered["id"] == to_uuid(option.id)
      assert rendered["label"] == "Large"
      assert rendered["retiredAt"] == nil
      assert second["id"] == to_uuid(note.id)
      assert second["valueType"] == "text"
      assert second["options"] == []
    end

    test "allows any authenticated member role to read", %{conn: _conn} do
      category = insert_category!()

      for role <- @read_roles do
        conn =
          build_conn()
          |> auth_conn(role)
          |> get("/api/inventory/categories/#{to_uuid(category.id)}/definitions")

        assert %{"data" => %{"definitions" => _}} = json_response(conn, 200)
      end
    end

    test "returns 401 without a bearer token", %{conn: conn} do
      conn = get(conn, "/api/inventory/categories/#{Ecto.UUID.generate()}/definitions")
      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end
  end

  # ── Definitions: create ─────────────────────────────────────────

  describe "definitions create" do
    test "creates a definition and returns 201 for write roles", %{conn: _conn} do
      category = insert_category!()

      for role <- @write_roles do
        conn =
          build_conn()
          |> auth_conn(role)
          |> post("/api/inventory/categories/#{to_uuid(category.id)}/definitions", %{
            "label" => "Brand #{role}",
            "valueType" => "text"
          })

        assert %{"data" => payload} = json_response(conn, 201)
        assert payload["label"] == "Brand #{role}"
        assert payload["valueType"] == "text"
        assert payload["required"] == false
        assert payload["identifyingPosition"] == nil
        assert payload["retiredAt"] == nil
        assert payload["categoryId"] == to_uuid(category.id)
        assert payload["options"] == []
      end
    end

    test "returns 403 for non-write roles", %{conn: conn} do
      category = insert_category!()

      conn =
        conn
        |> auth_conn("member")
        |> post("/api/inventory/categories/#{to_uuid(category.id)}/definitions", %{
          "label" => "Blocked",
          "valueType" => "text"
        })

      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
    end

    test "returns 409 when the label already exists case-insensitively", %{conn: conn} do
      category = insert_category!()

      assert {:ok, _} =
               Inventory.create_definition(category.id, %{
                 "label" => "Size",
                 "valueType" => "text"
               })

      conn =
        conn
        |> auth_conn("admin")
        |> post("/api/inventory/categories/#{to_uuid(category.id)}/definitions", %{
          "label" => "size",
          "valueType" => "text"
        })

      assert %{"errors" => %{"detail" => "A definition with that label already exists"}} =
               json_response(conn, 409)
    end

    test "returns 404 when the category does not exist", %{conn: conn} do
      conn =
        conn
        |> auth_conn("admin")
        |> post("/api/inventory/categories/#{Ecto.UUID.generate()}/definitions", %{
          "label" => "Orphan",
          "valueType" => "text"
        })

      assert %{"errors" => %{"detail" => "Category not found"}} = json_response(conn, 404)
    end
  end

  # ── Definitions: show / update / retire ─────────────────────────

  describe "definitions show" do
    test "returns a single definition by id", %{conn: conn} do
      category = insert_category!()

      assert {:ok, definition} =
               Inventory.create_definition(category.id, %{
                 "label" => "Size",
                 "valueType" => "text"
               })

      conn =
        conn
        |> auth_conn("member")
        |> get("/api/inventory/definitions/#{to_uuid(definition.id)}")

      assert %{"data" => payload} = json_response(conn, 200)
      assert payload["id"] == to_uuid(definition.id)
      assert payload["label"] == "Size"
      assert payload["valueType"] == "text"
    end

    test "returns 404 for an unknown id", %{conn: conn} do
      conn =
        conn
        |> auth_conn("member")
        |> get("/api/inventory/definitions/#{Ecto.UUID.generate()}")

      assert %{"errors" => %{"detail" => "Definition not found"}} = json_response(conn, 404)
    end
  end

  describe "definitions update" do
    test "renames, requires, and reorders identifying position", %{conn: conn} do
      category = insert_category!()

      assert {:ok, definition} =
               Inventory.create_definition(category.id, %{
                 "label" => "Size",
                 "valueType" => "text"
               })

      conn =
        conn
        |> auth_conn("quartermaster")
        |> patch("/api/inventory/definitions/#{to_uuid(definition.id)}", %{
          "label" => "Blade size",
          "required" => true,
          "identifyingPosition" => 0
        })

      assert %{"data" => payload} = json_response(conn, 200)
      assert payload["label"] == "Blade size"
      assert payload["required"] == true
      assert payload["identifyingPosition"] == 0
    end

    test "rejects a type change on a used definition with type_immutable", %{conn: conn} do
      category = insert_category!()

      assert {:ok, definition} =
               Inventory.create_definition(category.id, %{
                 "label" => "Count",
                 "valueType" => "text"
               })

      container_id = insert_container!()
      {:ok, item_id} = insert_item(container_id, category.id)
      insert_text_value!(item_id, definition.id, "large")

      conn =
        conn
        |> auth_conn("admin")
        |> patch("/api/inventory/definitions/#{to_uuid(definition.id)}", %{
          "valueType" => "decimal"
        })

      assert %{
               "errors" => %{
                 "detail" => "valueType cannot change once the definition is used",
                 "code" => "type_immutable"
               }
             } = json_response(conn, 422)
    end

    test "blocks make-required until every active item has a valid value", %{conn: conn} do
      category = insert_category!()

      assert {:ok, definition} =
               Inventory.create_definition(category.id, %{
                 "label" => "Size",
                 "valueType" => "text"
               })

      container_id = insert_container!()
      {:ok, empty_item} = insert_item(container_id, category.id)

      conn =
        conn
        |> auth_conn("admin")
        |> patch("/api/inventory/definitions/#{to_uuid(definition.id)}", %{
          "required" => true
        })

      assert %{
               "errors" => %{
                 "detail" => "required cannot be set until every active item has a valid value",
                 "code" => "required_blocked",
                 "itemIds" => item_ids
               }
             } = json_response(conn, 422)

      assert item_ids == [empty_item]
    end
  end

  describe "definitions retire" do
    test "retires an unused definition", %{conn: conn} do
      category = insert_category!()

      assert {:ok, definition} =
               Inventory.create_definition(category.id, %{
                 "label" => "Size",
                 "valueType" => "text"
               })

      conn =
        conn
        |> auth_conn("admin")
        |> post("/api/inventory/definitions/#{to_uuid(definition.id)}/retire")

      assert %{"data" => payload} = json_response(conn, 200)
      assert payload["id"] == to_uuid(definition.id)
      assert is_binary(payload["retiredAt"])
    end

    test "rejects retire while active values still reference the definition", %{conn: conn} do
      category = insert_category!()

      assert {:ok, definition} =
               Inventory.create_definition(category.id, %{
                 "label" => "Size",
                 "valueType" => "text"
               })

      container_id = insert_container!()
      {:ok, item_id} = insert_item(container_id, category.id)
      insert_text_value!(item_id, definition.id, "large")

      conn =
        conn
        |> auth_conn("admin")
        |> post("/api/inventory/definitions/#{to_uuid(definition.id)}/retire")

      assert %{
               "errors" => %{
                 "detail" => "definition is still referenced by active item values",
                 "code" => "still_referenced",
                 "activeValueCount" => 1
               }
             } = json_response(conn, 409)
    end
  end

  # ── Options ─────────────────────────────────────────────────────

  describe "options create / update / retire" do
    test "creates, lists, and retires options on a single-select definition", %{conn: conn} do
      category = insert_category!()

      assert {:ok, definition} =
               Inventory.create_definition(category.id, %{
                 "label" => "Guard",
                 "valueType" => "single_select"
               })

      create_conn =
        conn
        |> auth_conn("quartermaster")
        |> post("/api/inventory/definitions/#{to_uuid(definition.id)}/options", %{
          "label" => "Large"
        })

      assert %{"data" => created} = json_response(create_conn, 201)
      assert created["label"] == "Large"
      assert created["propertyDefinitionId"] == to_uuid(definition.id)
      assert created["retiredAt"] == nil

      list_conn =
        build_conn()
        |> auth_conn("member")
        |> get("/api/inventory/definitions/#{to_uuid(definition.id)}/options")

      assert %{"data" => %{"options" => [listed]}} = json_response(list_conn, 200)
      assert listed["id"] == created["id"]

      retire_conn =
        build_conn()
        |> auth_conn("admin")
        |> post("/api/inventory/options/#{created["id"]}/retire")

      assert %{"data" => retired} = json_response(retire_conn, 200)
      assert is_binary(retired["retiredAt"])
    end

    test "rejects options on a non-single-select definition", %{conn: conn} do
      category = insert_category!()

      assert {:ok, definition} =
               Inventory.create_definition(category.id, %{
                 "label" => "Note",
                 "valueType" => "text"
               })

      conn =
        conn
        |> auth_conn("admin")
        |> post("/api/inventory/definitions/#{to_uuid(definition.id)}/options", %{
          "label" => "Nope"
        })

      assert %{
               "errors" => %{
                 "detail" => "options are only allowed on single_select definitions",
                 "code" => "not_single_select"
               }
             } = json_response(conn, 422)
    end
  end

  # ── Containers: dedicated commands ──────────────────────────────

  describe "container move / archive / restore" do
    test "moves a container via the dedicated command", %{conn: conn} do
      parent = create_container!("Root")
      child = create_container!("Child", parent.id)
      destination = create_container!("Destination")

      conn =
        conn
        |> auth_conn("quartermaster")
        |> post("/api/inventory/containers/#{to_uuid(child.id)}/move", %{
          "parentContainerId" => destination.id
        })

      assert %{"data" => payload} = json_response(conn, 200)
      assert payload["parentContainerId"] == to_uuid(destination.id)
    end

    test "rejects a circular parent on move", %{conn: conn} do
      parent = create_container!("Root")
      child = create_container!("Child", parent.id)

      conn =
        conn
        |> auth_conn("admin")
        |> post("/api/inventory/containers/#{to_uuid(parent.id)}/move", %{
          "parentContainerId" => child.id
        })

      assert %{"errors" => %{"detail" => "parentContainerId would create a cycle"}} =
               json_response(conn, 422)
    end

    test "archives and restores when dependants are handled explicitly", %{conn: conn} do
      container = create_container!("Empty")

      archive_conn =
        conn
        |> auth_conn("admin")
        |> post("/api/inventory/containers/#{to_uuid(container.id)}/archive")

      assert %{"data" => archived} = json_response(archive_conn, 200)
      assert is_binary(archived["archivedAt"])

      restore_conn =
        build_conn()
        |> auth_conn("admin")
        |> post("/api/inventory/containers/#{to_uuid(container.id)}/restore")

      assert %{"data" => restored} = json_response(restore_conn, 200)
      assert restored["archivedAt"] == nil
    end

    test "rejects archive while active children remain", %{conn: conn} do
      parent = create_container!("Parent")
      _child = create_container!("Child", parent.id)

      conn =
        conn
        |> auth_conn("admin")
        |> post("/api/inventory/containers/#{to_uuid(parent.id)}/archive")

      assert %{
               "errors" => %{
                 "detail" => "container still has active child containers or items",
                 "code" => "active_dependants"
               }
             } = json_response(conn, 409)
    end
  end

  defp create_container!(name, parent_id \\ nil) do
    attrs = %{"name" => name}
    attrs = if parent_id, do: Map.put(attrs, "parentContainerId", parent_id), else: attrs
    {:ok, container} = Inventory.create_container(attrs, @actor_id)
    container
  end

  defp insert_container! do
    create_container!("Struct Container #{System.unique_integer([:positive])}").id
  end

  defp insert_item(container_id, category_id) do
    item_id = Ecto.UUID.generate()

    Dhc.Repo.query!(
      "INSERT INTO inventory_items (id, container_id, category_id, attributes, quantity, created_at, updated_at) VALUES ($1, $2, $3, '{}'::jsonb, 1, NOW(), NOW())",
      [Ecto.UUID.dump!(item_id), Ecto.UUID.dump!(container_id), Ecto.UUID.dump!(category_id)]
    )

    {:ok, item_id}
  end

  defp insert_text_value!(item_id, definition_id, text) do
    Dhc.Repo.query!(
      "INSERT INTO inventory_item_property_values (item_id, property_definition_id, text_value, created_at, updated_at) VALUES ($1, $2, $3, NOW(), NOW())",
      [Ecto.UUID.dump!(item_id), Ecto.UUID.dump!(definition_id), text]
    )
  end

  # ── OpenAPI contract backstops (ALE-292 review) ─────────────────

  describe "openapi structure contract" do
    test "definition and option operations live on the Inventory tag with typed extras" do
      spec = load_openapi_spec!()

      Enum.each(structure_operations(), fn {path, method, operation_id} ->
        operation = get_in(spec, ["paths", path, method])
        assert operation, "missing #{method} #{path}"
        assert operation["operationId"] == operation_id
        assert operation["tags"] == ["Inventory"]
        assert operation["security"] == [%{"cookieSession" => []}]
      end)

      update_422 =
        get_in(spec, [
          "paths",
          "/inventory/definitions/{id}",
          "patch",
          "responses",
          "422",
          "content",
          "application/json",
          "schema",
          "$ref"
        ])

      retire_409 =
        get_in(spec, [
          "paths",
          "/inventory/definitions/{id}/retire",
          "post",
          "responses",
          "409",
          "content",
          "application/json",
          "schema",
          "$ref"
        ])

      option_retire_409 =
        get_in(spec, [
          "paths",
          "/inventory/options/{id}/retire",
          "post",
          "responses",
          "409",
          "content",
          "application/json",
          "schema",
          "$ref"
        ])

      assert update_422 == "#/components/schemas/InventoryDefinitionUpdateError"
      assert retire_409 == "#/components/schemas/InventoryDefinitionRetireError"
      assert option_retire_409 == "#/components/schemas/InventoryOptionRetireError"

      update_error = get_in(spec, ["components", "schemas", "InventoryDefinitionUpdateError"])
      retire_error = get_in(spec, ["components", "schemas", "InventoryDefinitionRetireError"])
      option_error = get_in(spec, ["components", "schemas", "InventoryOptionRetireError"])

      assert update_error["required"] == ["errors"]

      assert get_in(update_error, ["properties", "errors", "properties", "itemIds", "type"]) ==
               "array"

      assert get_in(update_error, ["properties", "errors", "properties", "code", "enum"]) ==
               ["type_immutable", "required_blocked"]

      assert get_in(retire_error, ["properties", "errors", "required"]) ==
               ["detail", "code", "activeValueCount"]

      assert get_in(option_error, ["properties", "errors", "required"]) ==
               ["detail", "code", "activeValueCount"]
    end

    test "category and container viewer operations declare cookieSession" do
      spec = load_openapi_spec!()

      Enum.each(structure_owned_legacy_operations(), fn {path, method} ->
        operation = get_in(spec, ["paths", path, method])
        assert operation, "missing #{method} #{path}"
        assert operation["security"] == [%{"cookieSession" => []}]
        refute operation["description"] =~ "Supabase JWT"
        refute operation["description"] =~ "auth.users"
      end)

      refute spec["info"]["description"] =~ "Supabase JWT"
      assert spec["info"]["description"] =~ "cookieSession"
    end
  end

  defp structure_operations do
    [
      {"/inventory/categories/{categoryId}/definitions", "get",
       "inventoryStructure.listDefinitions"},
      {"/inventory/categories/{categoryId}/definitions", "post",
       "inventoryStructure.createDefinition"},
      {"/inventory/definitions/{id}", "get", "inventoryStructure.showDefinition"},
      {"/inventory/definitions/{id}", "patch", "inventoryStructure.updateDefinition"},
      {"/inventory/definitions/{id}/retire", "post", "inventoryStructure.retireDefinition"},
      {"/inventory/definitions/{definitionId}/options", "get", "inventoryStructure.listOptions"},
      {"/inventory/definitions/{definitionId}/options", "post",
       "inventoryStructure.createOption"},
      {"/inventory/options/{id}", "patch", "inventoryStructure.updateOption"},
      {"/inventory/options/{id}/retire", "post", "inventoryStructure.retireOption"}
    ]
  end

  defp structure_owned_legacy_operations do
    [
      {"/inventory/categories", "get"},
      {"/inventory/categories", "post"},
      {"/inventory/categories/{id}", "get"},
      {"/inventory/categories/{id}", "patch"},
      {"/inventory/categories/{id}", "delete"},
      {"/inventory/containers", "get"},
      {"/inventory/containers", "post"},
      {"/inventory/containers/{id}", "get"},
      {"/inventory/containers/{id}", "patch"},
      {"/inventory/containers/{id}", "delete"},
      {"/inventory/containers/{id}/move", "post"},
      {"/inventory/containers/{id}/archive", "post"},
      {"/inventory/containers/{id}/restore", "post"}
    ]
  end

  defp load_openapi_spec! do
    path = Application.app_dir(:dhc, "priv/api/openapi.yaml")

    case YamlElixir.read_from_file(path) do
      {:ok, spec} -> spec
      {:error, error} -> flunk("failed to parse OpenAPI spec: #{inspect(error)}")
    end
  end
end
