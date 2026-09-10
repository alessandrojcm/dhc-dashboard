defmodule DhcWeb.InventoryOperatorItemsControllerTest do
  @moduledoc """
  Request/contract tests for ALE-295 (ALE-284c) operator item viewers.

  Covers the viewer-shaped payload (derived label, slug, typed values,
  availability projection, no internal or legacy fields), the
  command-specific requests (a generic edit that cannot move, maintain, or
  archive), slug-or-id resolution, cursor pagination with exact counts and
  filters, role gates with equal quartermaster/president/admin authority,
  and the typed error mapping for interlock conflicts and per-definition
  value failures.

  Domain invariants themselves live in `Dhc.Inventory.OperatorItemsTest`,
  `Dhc.Inventory.OperatorItemLifecycleTest`, and
  `Dhc.Inventory.OperatorItemListTest`.
  """

  use DhcWeb.ConnCase, async: false

  alias Dhc.Inventory

  @actor_id "22222222-2222-2222-2222-222222222222"
  # Equal operator authority; this viewer has no member-readable variant
  # (ALE-280 story 45 — the member catalog is ALE-285).
  @write_roles ~w(quartermaster admin president)

  defmodule Verifier do
    @actor_id "22222222-2222-2222-2222-222222222222"

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

    def verify(_token), do: {:error, :invalid_token}
  end

  setup do
    original = Application.get_env(:dhc, :auth_verifier)
    Application.put_env(:dhc, :auth_verifier, Verifier)

    {:ok, _} = Dhc.Auth.register_principal_with_id(@actor_id, %{email: "inv-items@example.com"})

    on_exit(fn -> Application.put_env(:dhc, :auth_verifier, original) end)

    :ok
  end

  defp auth_conn(conn, role), do: put_req_header(conn, "authorization", "Bearer #{role}-token")

  # ── Show: viewer shape and slug resolution ──────────────────────

  describe "show" do
    test "returns the viewer shape with derived label, values, and availability", %{conn: conn} do
      %{category: category, container_id: container_id} = fixture()
      {:ok, brand} = definition(category.id, "Brand", "text", identifying_position: 0)
      {:ok, sharp} = definition(category.id, "Sharp", "boolean")

      {:ok, item} =
        create_item(container_id, category.id, %{brand.id => "Regenyei", sharp.id => true})

      conn =
        conn |> auth_conn("quartermaster") |> get("/api/inventory/operator/items/#{item.slug}")

      assert %{"data" => payload} = json_response(conn, 200)

      assert payload["id"] == item.id
      assert payload["slug"] == item.slug
      assert payload["label"] == "#{category.name} · Regenyei"
      assert payload["categoryId"] == category.id
      assert payload["containerId"] == container_id

      assert payload["category"] == %{
               "id" => category.id,
               "name" => category.name,
               "archivedAt" => nil
             }

      assert payload["container"]["id"] == container_id
      assert payload["notes"] == nil
      assert payload["archivedAt"] == nil
      assert payload["availability"] == %{"available" => true, "status" => "available"}

      brand_value = Enum.find(payload["values"], &(&1["definitionId"] == brand.id))
      assert brand_value["definitionLabel"] == "Brand"
      assert brand_value["valueType"] == "text"
      assert brand_value["text"] == "Regenyei"
      assert brand_value["identifyingPosition"] == 0
      assert brand_value["boolean"] == nil
      assert brand_value["optionId"] == nil

      sharp_value = Enum.find(payload["values"], &(&1["definitionId"] == sharp.id))
      assert sharp_value["boolean"] == true
      assert sharp_value["valueType"] == "boolean"
    end

    test "omits internal, legacy, and privacy-sensitive fields", %{conn: conn} do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      conn =
        conn |> auth_conn("quartermaster") |> get("/api/inventory/operator/items/#{item.slug}")

      assert %{"data" => payload} = json_response(conn, 200)

      for absent <- ~w(quantity photoUrl attributes outForMaintenance createdBy updatedBy
                       createdAt updatedAt archivedByPrincipalId) do
        refute Map.has_key?(payload, absent), "#{absent} must not be exposed"
      end

      assert Enum.sort(Map.keys(payload)) ==
               Enum.sort(~w(id slug label categoryId containerId category container values notes
                    availability archivedAt))
    end

    test "resolves by slug or id and 404s otherwise", %{conn: conn} do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      by_slug =
        conn |> auth_conn("quartermaster") |> get("/api/inventory/operator/items/#{item.slug}")

      assert json_response(by_slug, 200)["data"]["id"] == item.id

      by_id =
        build_conn()
        |> auth_conn("quartermaster")
        |> get("/api/inventory/operator/items/#{item.id}")

      assert json_response(by_id, 200)["data"]["slug"] == item.slug

      missing =
        build_conn()
        |> auth_conn("quartermaster")
        |> get("/api/inventory/operator/items/item-999999")

      assert %{"errors" => %{"detail" => "Item not found"}} = json_response(missing, 404)
    end

    test "grants every operator role equal read authority and 401s without a session", %{
      conn: conn
    } do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      for role <- @write_roles do
        read =
          build_conn() |> auth_conn(role) |> get("/api/inventory/operator/items/#{item.slug}")

        assert json_response(read, 200)["data"]["slug"] == item.slug
      end

      anonymous = get(conn, "/api/inventory/operator/items/#{item.slug}")
      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(anonymous, 401)
    end

    # Spec ALE-280 story 45: a member must never see container location or
    # operator facts in ordinary browsing. The member catalog is ALE-285, so
    # this viewer refuses members outright rather than shrinking its payload.
    test "refuses members, who must not see containers or operator facts", %{conn: conn} do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      show = conn |> auth_conn("member") |> get("/api/inventory/operator/items/#{item.slug}")
      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(show, 403)

      list = build_conn() |> auth_conn("member") |> get("/api/inventory/operator/items")
      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(list, 403)
    end
  end

  # ── List: pagination, counts, filters ───────────────────────────

  describe "index" do
    test "returns a page with exact totalCount and cursor metadata", %{conn: conn} do
      %{category: category, container_id: container_id} = fixture()

      slugs =
        for _ <- 1..12 do
          {:ok, item} = create_item(container_id, category.id)
          item.slug
        end

      sorted = Enum.sort(slugs)

      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/operator/items", %{"limit" => "10"})

      assert %{"data" => data} = json_response(conn, 200)
      assert Enum.map(data["items"], & &1["slug"]) == Enum.take(sorted, 10)
      assert data["totalCount"] == 12
      assert data["limit"] == 10
      assert is_binary(data["nextCursor"])
      assert data["previousCursor"] == nil

      next =
        build_conn()
        |> auth_conn("quartermaster")
        |> get("/api/inventory/operator/items", %{"limit" => "10", "cursor" => data["nextCursor"]})

      assert %{"data" => page_two} = json_response(next, 200)
      assert Enum.map(page_two["items"], & &1["slug"]) == Enum.drop(sorted, 10)
      assert page_two["totalCount"] == 12
      assert page_two["nextCursor"] == nil
    end

    test "hides archived items unless the archive filter asks for them", %{conn: conn} do
      %{category: category, container_id: container_id} = fixture()
      {:ok, active} = create_item(container_id, category.id)
      {:ok, retired} = create_item(container_id, category.id)

      assert {:ok, _} = Inventory.archive_operator_item(retired.slug, %{}, @actor_id)

      default = conn |> auth_conn("quartermaster") |> get("/api/inventory/operator/items")
      assert %{"data" => data} = json_response(default, 200)
      assert Enum.map(data["items"], & &1["id"]) == [active.id]

      only =
        build_conn()
        |> auth_conn("quartermaster")
        |> get("/api/inventory/operator/items", %{"archived" => "only"})

      assert %{"data" => archived} = json_response(only, 200)
      assert Enum.map(archived["items"], & &1["id"]) == [retired.id]

      assert [%{"availability" => %{"status" => "archived", "available" => false}}] =
               archived["items"]
    end

    test "filters by category and property", %{conn: conn} do
      %{category: category, container_id: container_id} = fixture()
      other = category!()
      {:ok, size} = definition(category.id, "Size", "single_select")
      {:ok, large} = Inventory.create_option(size.id, %{"label" => "Large"})

      {:ok, big} = create_item(container_id, category.id, %{size.id => large.id})
      {:ok, _small} = create_item(container_id, category.id)
      {:ok, _elsewhere} = create_item(container_id, other.id)

      by_category =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/operator/items", %{"categoryId" => category.id})

      assert %{"data" => data} = json_response(by_category, 200)
      assert data["totalCount"] == 2

      by_property =
        build_conn()
        |> auth_conn("quartermaster")
        |> get("/api/inventory/operator/items", %{"property" => "#{size.id}:#{large.id}"})

      assert %{"data" => filtered} = json_response(by_property, 200)
      assert Enum.map(filtered["items"], & &1["id"]) == [big.id]
      assert filtered["totalCount"] == 1
    end

    test "400s an invalid limit, filter, or mismatched cursor", %{conn: conn} do
      %{category: category, container_id: container_id} = fixture()
      for _ <- 1..12, do: create_item(container_id, category.id)

      bad_limit =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/operator/items", %{"limit" => "7"})

      assert %{"errors" => %{"detail" => detail}} = json_response(bad_limit, 400)
      assert detail =~ "limit"

      bad_archived =
        build_conn()
        |> auth_conn("quartermaster")
        |> get("/api/inventory/operator/items", %{"archived" => "yes"})

      assert json_response(bad_archived, 400)

      bad_property =
        build_conn()
        |> auth_conn("quartermaster")
        |> get("/api/inventory/operator/items", %{"property" => "nope"})

      assert json_response(bad_property, 400)

      first =
        build_conn()
        |> auth_conn("quartermaster")
        |> get("/api/inventory/operator/items", %{"limit" => "10"})

      cursor = json_response(first, 200)["data"]["nextCursor"]

      mismatched =
        build_conn()
        |> auth_conn("quartermaster")
        |> get("/api/inventory/operator/items", %{
          "limit" => "10",
          "cursor" => cursor,
          "categoryId" => Ecto.UUID.generate()
        })

      assert %{"errors" => %{"detail" => cursor_detail}} = json_response(mismatched, 400)
      assert cursor_detail =~ "cursor"
    end
  end

  # ── Create ──────────────────────────────────────────────────────

  describe "create" do
    test "creates an item for every write role with a minted slug", %{conn: _conn} do
      %{category: category, container_id: container_id} = fixture()

      for role <- @write_roles do
        conn =
          build_conn()
          |> auth_conn(role)
          |> post("/api/inventory/operator/items", %{
            "containerId" => container_id,
            "categoryId" => category.id,
            "notes" => "Bought #{role}"
          })

        assert %{"data" => payload} = json_response(conn, 201)
        assert payload["slug"] =~ ~r/^item-\d{6,}$/
        assert payload["notes"] == "Bought #{role}"
        assert payload["availability"]["status"] == "available"
      end
    end

    test "403s a member and 422s per-definition value errors", %{conn: conn} do
      %{category: category, container_id: container_id} = fixture()
      {:ok, required} = definition(category.id, "Serial", "text", required: true)

      blocked =
        conn
        |> auth_conn("member")
        |> post("/api/inventory/operator/items", %{
          "containerId" => container_id,
          "categoryId" => category.id
        })

      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(blocked, 403)

      invalid =
        build_conn()
        |> auth_conn("quartermaster")
        |> post("/api/inventory/operator/items", %{
          "containerId" => container_id,
          "categoryId" => category.id,
          "values" => %{}
        })

      assert %{
               "errors" => %{
                 "code" => "invalid_values",
                 "valueErrors" => value_errors
               }
             } = json_response(invalid, 422)

      assert value_errors == %{required.id => "required"}
    end

    test "422s an archived container and 404s an unknown category", %{conn: conn} do
      %{category: category} = fixture()
      archived = container!()
      assert {:ok, _} = Inventory.archive_container(archived.id)

      conn =
        conn
        |> auth_conn("admin")
        |> post("/api/inventory/operator/items", %{
          "containerId" => archived.id,
          "categoryId" => category.id
        })

      assert %{"errors" => %{"code" => "archived_container"}} = json_response(conn, 422)

      unknown =
        build_conn()
        |> auth_conn("admin")
        |> post("/api/inventory/operator/items", %{
          "containerId" => container!().id,
          "categoryId" => Ecto.UUID.generate()
        })

      assert json_response(unknown, 404)
    end
  end

  # ── Generic edit is narrow by construction ──────────────────────

  describe "update" do
    test "edits notes and values", %{conn: conn} do
      %{category: category, container_id: container_id} = fixture()
      {:ok, brand} = definition(category.id, "Brand", "text")
      {:ok, item} = create_item(container_id, category.id, %{brand.id => "Old"})

      conn =
        conn
        |> auth_conn("quartermaster")
        |> patch("/api/inventory/operator/items/#{item.slug}", %{
          "notes" => "Rebound grip",
          "values" => %{brand.id => "New"}
        })

      assert %{"data" => payload} = json_response(conn, 200)
      assert payload["notes"] == "Rebound grip"
      assert [%{"text" => "New"}] = payload["values"]
    end

    test "never moves, reclassifies, or unarchives through the generic patch", %{conn: conn} do
      %{category: category, container_id: container_id} = fixture()
      other_category = category!()
      other_container = container!()
      {:ok, item} = create_item(container_id, category.id)

      conn =
        conn
        |> auth_conn("admin")
        |> patch("/api/inventory/operator/items/#{item.slug}", %{
          "containerId" => other_container.id,
          "categoryId" => other_category.id,
          "archivedAt" => nil,
          "notes" => "untouched by the rest"
        })

      assert %{"data" => payload} = json_response(conn, 200)
      assert payload["containerId"] == container_id
      assert payload["categoryId"] == category.id
      assert payload["notes"] == "untouched by the rest"
    end

    test "409s an archived item as a domain conflict", %{conn: conn} do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)
      assert {:ok, _} = Inventory.archive_operator_item(item.slug, %{}, @actor_id)

      conn =
        conn
        |> auth_conn("admin")
        |> patch("/api/inventory/operator/items/#{item.slug}", %{"notes" => "nope"})

      assert %{"errors" => %{"code" => "archived"}} = json_response(conn, 409)
    end
  end

  # ── Dedicated commands ──────────────────────────────────────────

  describe "move" do
    test "moves to another container and is allowed during maintenance", %{conn: conn} do
      %{category: category, container_id: container_id} = fixture()
      destination = container!()
      {:ok, item} = create_item(container_id, category.id)

      assert {:ok, _} =
               Inventory.start_operator_item_maintenance(
                 item.slug,
                 %{"reason" => "Bent"},
                 @actor_id
               )

      conn =
        conn
        |> auth_conn("quartermaster")
        |> post("/api/inventory/operator/items/#{item.slug}/move", %{
          "containerId" => destination.id
        })

      assert %{"data" => payload} = json_response(conn, 200)
      assert payload["containerId"] == destination.id
      assert payload["availability"]["status"] == "maintenance"
    end

    test "422s an archived destination container", %{conn: conn} do
      %{category: category, container_id: container_id} = fixture()
      destination = container!()
      {:ok, item} = create_item(container_id, category.id)
      assert {:ok, _} = Inventory.archive_container(destination.id)

      conn =
        conn
        |> auth_conn("admin")
        |> post("/api/inventory/operator/items/#{item.slug}/move", %{
          "containerId" => destination.id
        })

      assert %{"errors" => %{"code" => "archived_container"}} = json_response(conn, 422)
    end
  end

  describe "category" do
    test "reclassifies atomically with the new category's values", %{conn: conn} do
      %{category: category, container_id: container_id} = fixture()
      target = category!()
      {:ok, serial} = definition(target.id, "Serial", "text", required: true)
      {:ok, item} = create_item(container_id, category.id)

      conn =
        conn
        |> auth_conn("admin")
        |> post("/api/inventory/operator/items/#{item.slug}/category", %{
          "categoryId" => target.id,
          "values" => %{serial.id => "SN-1"}
        })

      assert %{"data" => payload} = json_response(conn, 200)
      assert payload["categoryId"] == target.id
      assert payload["slug"] == item.slug
      assert [%{"text" => "SN-1"}] = payload["values"]
    end

    test "422s when the new category's required values are missing", %{conn: conn} do
      %{category: category, container_id: container_id} = fixture()
      target = category!()
      {:ok, serial} = definition(target.id, "Serial", "text", required: true)
      {:ok, item} = create_item(container_id, category.id)

      conn =
        conn
        |> auth_conn("admin")
        |> post("/api/inventory/operator/items/#{item.slug}/category", %{
          "categoryId" => target.id,
          "values" => %{}
        })

      assert %{"errors" => %{"code" => "invalid_values", "valueErrors" => errors}} =
               json_response(conn, 422)

      assert errors == %{serial.id => "required"}
    end
  end

  describe "maintenance" do
    test "starts, lists, and ends retained periods", %{conn: conn} do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      started =
        conn
        |> auth_conn("quartermaster")
        |> post("/api/inventory/operator/items/#{item.slug}/maintenance/start", %{
          "reason" => "Cracked guard"
        })

      assert %{"data" => payload} = json_response(started, 200)
      assert payload["availability"] == %{"available" => false, "status" => "maintenance"}

      listed =
        build_conn()
        |> auth_conn("admin")
        |> get("/api/inventory/operator/items/#{item.slug}/maintenance")

      assert %{"data" => %{"periods" => [period]}} = json_response(listed, 200)
      assert period["startReason"] == "Cracked guard"
      assert period["startedByPrincipalId"] == @actor_id
      assert period["open"] == true
      assert period["endedAt"] == nil
      assert is_binary(period["startedAt"])

      ended =
        build_conn()
        |> auth_conn("admin")
        |> post("/api/inventory/operator/items/#{item.slug}/maintenance/end", %{
          "endNote" => "Guard replaced"
        })

      assert %{"data" => back} = json_response(ended, 200)
      assert back["availability"]["status"] == "available"

      after_end =
        build_conn()
        |> auth_conn("admin")
        |> get("/api/inventory/operator/items/#{item.slug}/maintenance")

      assert %{"data" => %{"periods" => [closed]}} = json_response(after_end, 200)
      assert closed["open"] == false
      assert closed["endNote"] == "Guard replaced"
      assert closed["endedByPrincipalId"] == @actor_id
    end

    test "422s a missing reason and 409s a second open period", %{conn: conn} do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      missing_reason =
        conn
        |> auth_conn("admin")
        |> post("/api/inventory/operator/items/#{item.slug}/maintenance/start", %{})

      assert %{"errors" => %{"code" => "reason_required"}} = json_response(missing_reason, 422)

      assert {:ok, _} =
               Inventory.start_operator_item_maintenance(
                 item.slug,
                 %{"reason" => "First"},
                 @actor_id
               )

      already_open =
        build_conn()
        |> auth_conn("admin")
        |> post("/api/inventory/operator/items/#{item.slug}/maintenance/start", %{
          "reason" => "Second"
        })

      assert %{"errors" => %{"code" => "maintenance_open"}} = json_response(already_open, 409)
    end

    test "409s ending when no period is open", %{conn: conn} do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      conn =
        conn
        |> auth_conn("admin")
        |> post("/api/inventory/operator/items/#{item.slug}/maintenance/end", %{})

      assert %{"errors" => %{"code" => "no_open_maintenance"}} = json_response(conn, 409)
    end

    test "403s a member reading operator maintenance facts", %{conn: conn} do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      conn =
        conn
        |> auth_conn("member")
        |> get("/api/inventory/operator/items/#{item.slug}/maintenance")

      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(conn, 403)
    end
  end

  describe "archive and restore" do
    test "archives with a reason then restores", %{conn: conn} do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      archived =
        conn
        |> auth_conn("quartermaster")
        |> post("/api/inventory/operator/items/#{item.slug}/archive", %{"reason" => "Retired"})

      assert %{"data" => payload} = json_response(archived, 200)
      assert is_binary(payload["archivedAt"])
      assert payload["availability"] == %{"available" => false, "status" => "archived"}

      restored =
        build_conn()
        |> auth_conn("admin")
        |> post("/api/inventory/operator/items/#{item.slug}/restore")

      assert %{"data" => back} = json_response(restored, 200)
      assert back["archivedAt"] == nil
      assert back["availability"]["status"] == "available"
    end

    test "422s a restore whose category is archived", %{conn: conn} do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)
      assert {:ok, _} = Inventory.archive_operator_item(item.slug, %{}, @actor_id)

      Dhc.Repo.query!("UPDATE equipment_categories SET archived_at = NOW() WHERE id = $1", [
        Ecto.UUID.dump!(category.id)
      ])

      conn =
        conn
        |> auth_conn("admin")
        |> post("/api/inventory/operator/items/#{item.slug}/restore")

      assert %{"errors" => %{"code" => "archived_category"}} = json_response(conn, 422)
    end

    test "closes an open maintenance period with the archive reason", %{conn: conn} do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      assert {:ok, _} =
               Inventory.start_operator_item_maintenance(
                 item.slug,
                 %{"reason" => "Bent"},
                 @actor_id
               )

      archived =
        conn
        |> auth_conn("admin")
        |> post("/api/inventory/operator/items/#{item.slug}/archive", %{"reason" => "Beyond
        repair"})

      assert json_response(archived, 200)["data"]["availability"]["status"] == "archived"

      listed =
        build_conn()
        |> auth_conn("admin")
        |> get("/api/inventory/operator/items/#{item.slug}/maintenance")

      assert %{"data" => %{"periods" => [period]}} = json_response(listed, 200)
      assert period["open"] == false
      assert period["endNote"] =~ "Archived:"
    end
  end

  describe "delete" do
    test "deletes a history-free item with confirmation", %{conn: conn} do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      conn =
        conn
        |> auth_conn("admin")
        |> delete("/api/inventory/operator/items/#{item.slug}", %{"confirm" => true})

      assert %{"data" => payload} = json_response(conn, 200)
      assert payload["id"] == item.id

      assert {:error, :not_found} = Inventory.resolve_operator_item(item.slug)
    end

    test "422s without confirmation and 409s once history exists", %{conn: conn} do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      unconfirmed =
        conn
        |> auth_conn("admin")
        |> delete("/api/inventory/operator/items/#{item.slug}", %{"confirm" => "true"})

      assert %{"errors" => %{"code" => "confirmation_required"}} =
               json_response(unconfirmed, 422)

      assert {:ok, _} =
               Inventory.start_operator_item_maintenance(
                 item.slug,
                 %{"reason" => "Serviced once"},
                 @actor_id
               )

      historical =
        build_conn()
        |> auth_conn("admin")
        |> delete("/api/inventory/operator/items/#{item.slug}", %{"confirm" => true})

      assert %{"errors" => %{"code" => "has_history"}} = json_response(historical, 409)
    end
  end

  # ── OpenAPI contract backstops ──────────────────────────────────

  describe "openapi operator item contract" do
    test "every operator item operation lives on the one Inventory tag" do
      spec = load_openapi_spec!()

      Enum.each(operator_item_operations(), fn {path, method, operation_id} ->
        operation = get_in(spec, ["paths", path, method])
        assert operation, "missing #{method} #{path}"
        assert operation["operationId"] == operation_id
        assert operation["tags"] == ["Inventory"]
        assert operation["security"] == [%{"cookieSession" => []}]
        refute operation["description"] =~ "Supabase JWT"
      end)
    end

    test "the viewer schema exposes no internal or legacy item fields" do
      spec = load_openapi_spec!()
      item = get_in(spec, ["components", "schemas", "InventoryOperatorItem"])

      assert Enum.sort(Map.keys(item["properties"])) ==
               Enum.sort(~w(id slug label categoryId containerId category container values notes
                    availability archivedAt))

      for absent <- ~w(quantity photoUrl attributes outForMaintenance createdBy updatedBy) do
        refute Map.has_key?(item["properties"], absent)
      end

      availability =
        get_in(spec, ["components", "schemas", "InventoryOperatorItemAvailability"])

      assert get_in(availability, ["properties", "status", "enum"]) ==
               ~w(available maintenance on_loan archived)
    end

    test "command requests are separate and the generic patch cannot change state" do
      spec = load_openapi_spec!()

      patch_schema =
        get_in(spec, ["components", "schemas", "InventoryOperatorItemUpdateRequest"])

      assert Enum.sort(Map.keys(patch_schema["properties"])) == ~w(notes values)

      for forbidden <- ~w(containerId categoryId archivedAt outForMaintenance reason confirm) do
        refute Map.has_key?(patch_schema["properties"], forbidden),
               "the generic item patch must not carry #{forbidden}"
      end

      assert get_in(spec, [
               "components",
               "schemas",
               "InventoryOperatorItemMoveRequest",
               "required"
             ]) == ["containerId"]

      assert get_in(spec, [
               "components",
               "schemas",
               "InventoryMaintenanceStartRequest",
               "required"
             ]) == ["reason"]

      assert get_in(spec, [
               "components",
               "schemas",
               "InventoryOperatorItemDeleteRequest",
               "required"
             ]) == ["confirm"]
    end

    test "interlock conflicts and per-definition value errors are typed" do
      spec = load_openapi_spec!()

      conflict = get_in(spec, ["components", "schemas", "InventoryOperatorItemConflictError"])
      validation = get_in(spec, ["components", "schemas", "InventoryOperatorItemValidationError"])

      assert get_in(conflict, ["properties", "errors", "properties", "code", "enum"]) ==
               ~w(archived loan_active maintenance_open no_open_maintenance has_history)

      assert get_in(validation, ["properties", "errors", "properties", "code", "enum"]) ==
               ~w(invalid_values invalid_notes archived_category archived_container
                  reason_required confirmation_required)

      # Mirrors InventoryDefinitionUpdateError from ALE-292 so the generated
      # client can map a failing definition back to its form field.
      assert get_in(validation, [
               "properties",
               "errors",
               "properties",
               "valueErrors",
               "additionalProperties",
               "enum"
             ]) ==
               ~w(required type_mismatch unknown_option retired_option retired_definition
                  unknown_definition)
    end

    test "the list operation declares cursor pagination with exact counts" do
      spec = load_openapi_spec!()

      params =
        get_in(spec, ["paths", "/inventory/operator/items", "get", "parameters"])
        |> Map.new(&{&1["name"], &1})

      assert params["limit"]["schema"]["enum"] == [10, 25, 50, 100]
      assert params["archived"]["schema"]["enum"] == ~w(exclude include only)
      assert params["direction"]["schema"]["enum"] == ~w(asc desc)
      assert Map.has_key?(params, "cursor")
      assert Map.has_key?(params, "categoryId")
      assert Map.has_key?(params, "property")

      assert get_in(spec, [
               "paths",
               "/inventory/operator/items",
               "get",
               "responses",
               "400",
               "content",
               "application/json",
               "schema",
               "$ref"
             ]) == "#/components/schemas/Error"

      data =
        get_in(spec, [
          "components",
          "schemas",
          "InventoryOperatorItemListResponse",
          "properties",
          "data"
        ])

      assert data["required"] == ~w(items totalCount limit nextCursor previousCursor)
      assert get_in(data, ["properties", "totalCount", "minimum"]) == 0
    end
  end

  # ── Fixtures ────────────────────────────────────────────────────

  defp fixture, do: %{category: category!(), container_id: container!().id}

  defp create_item(container_id, category_id, values \\ %{}) do
    Inventory.create_operator_item(
      %{"container_id" => container_id, "category_id" => category_id, "values" => values},
      @actor_id
    )
  end

  defp definition(category_id, label, value_type, opts \\ []) do
    attrs = %{"label" => label, "value_type" => value_type}

    attrs =
      Enum.reduce(opts, attrs, fn
        {:required, required}, acc -> Map.put(acc, "required", required)
        {:identifying_position, position}, acc -> Map.put(acc, "identifying_position", position)
      end)

    Inventory.create_definition(category_id, attrs)
  end

  defp category! do
    {:ok, category} =
      Inventory.create_category(%{"name" => "Op cat #{System.unique_integer([:positive])}"})

    category
  end

  defp container! do
    {:ok, container} =
      Inventory.create_container(
        %{"name" => "Op container #{System.unique_integer([:positive])}"},
        @actor_id
      )

    container
  end

  defp operator_item_operations do
    [
      {"/inventory/operator/items", "get", "inventoryOperatorItems.list"},
      {"/inventory/operator/items", "post", "inventoryOperatorItems.create"},
      {"/inventory/operator/items/{slugOrId}", "get", "inventoryOperatorItems.show"},
      {"/inventory/operator/items/{slugOrId}", "patch", "inventoryOperatorItems.update"},
      {"/inventory/operator/items/{slugOrId}", "delete", "inventoryOperatorItems.delete"},
      {"/inventory/operator/items/{slugOrId}/category", "post",
       "inventoryOperatorItems.changeCategory"},
      {"/inventory/operator/items/{slugOrId}/move", "post", "inventoryOperatorItems.move"},
      {"/inventory/operator/items/{slugOrId}/maintenance", "get",
       "inventoryOperatorItems.listMaintenance"},
      {"/inventory/operator/items/{slugOrId}/maintenance/start", "post",
       "inventoryOperatorItems.startMaintenance"},
      {"/inventory/operator/items/{slugOrId}/maintenance/end", "post",
       "inventoryOperatorItems.endMaintenance"},
      {"/inventory/operator/items/{slugOrId}/archive", "post", "inventoryOperatorItems.archive"},
      {"/inventory/operator/items/{slugOrId}/restore", "post", "inventoryOperatorItems.restore"}
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
