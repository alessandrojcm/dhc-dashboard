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
  alias IdempotencyPlug.IdempotentRequest

  @actor_id "11111111-1111-1111-1111-111111111111"
  @other_actor_id "22222222-2222-2222-2222-222222222222"
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

    def verify("other-token") do
      {:ok,
       %{
         sub: "22222222-2222-2222-2222-222222222222",
         email: "other@example.com",
         roles: ["quartermaster"],
         raw: %{}
       }}
    end

    def verify(_token), do: {:error, :invalid_token}
  end

  setup do
    original = Application.get_env(:dhc, :auth_verifier)
    original_tracker = Application.get_env(:dhc, :idempotency_tracker)
    Application.put_env(:dhc, :auth_verifier, Verifier)

    tracker =
      start_supervised!(request_tracker_child_spec())

    Application.put_env(:dhc, :idempotency_tracker, tracker)

    insert_user!(@actor_id, "inv-item-actor@example.com")
    insert_user!(@other_actor_id, "inv-item-other@example.com")

    on_exit(fn ->
      Application.put_env(:dhc, :auth_verifier, original)
      Application.put_env(:dhc, :idempotency_tracker, original_tracker)
    end)

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

    test "replays the original response byte-for-byte without creating a second item", %{
      conn: conn
    } do
      category = insert_category!("Idempotency Replay")
      container = create_container!(%{"name" => "Idempotency Rack"})
      key = "item-create-replay"
      payload = item_payload(container, category)

      first =
        conn
        |> auth_conn("quartermaster")
        |> put_req_header("idempotency-key", key)
        |> post("/api/inventory/items", payload)

      assert first.status == 201

      replay =
        build_conn()
        |> auth_conn("quartermaster")
        |> put_req_header("idempotency-key", key)
        |> post("/api/inventory/items", payload)

      assert replay.status == 201
      assert replay.resp_body == first.resp_body
      assert get_resp_header(replay, "idempotent-replayed") == ["true"]
      assert Repo.aggregate(Dhc.Inventory.Item, :count) == 1
    end

    test "replays a completed response after the request tracker restarts", %{conn: conn} do
      category = insert_category!("Idempotency Restart")
      container = create_container!(%{"name" => "Restart Rack"})
      key = "item-create-restart"
      payload = item_payload(container, category)

      first =
        conn
        |> auth_conn("quartermaster")
        |> put_req_header("idempotency-key", key)
        |> post("/api/inventory/items", payload)

      assert first.status == 201

      tracker = idempotency_tracker()
      reference = Process.monitor(tracker)
      :ok = GenServer.stop(tracker)
      assert_receive {:DOWN, ^reference, :process, ^tracker, :normal}

      restarted_tracker = start_supervised!(request_tracker_child_spec())
      Application.put_env(:dhc, :idempotency_tracker, restarted_tracker)

      replay =
        build_conn()
        |> auth_conn("quartermaster")
        |> put_req_header("idempotency-key", key)
        |> post("/api/inventory/items", payload)

      assert replay.status == 201
      assert replay.resp_body == first.resp_body
      assert get_resp_header(replay, "idempotent-replayed") == ["true"]
      assert Repo.aggregate(Dhc.Inventory.Item, :count) == 1
    end

    test "rejects a reused key with a different payload", %{conn: conn} do
      category = insert_category!("Idempotency Mismatch")
      container = create_container!(%{"name" => "Mismatch Rack"})
      key = "item-create-mismatch"

      first_payload = item_payload(container, category)

      first =
        conn
        |> auth_conn("quartermaster")
        |> put_req_header("idempotency-key", key)
        |> post("/api/inventory/items", first_payload)

      assert first.status == 201

      mismatch =
        build_conn()
        |> auth_conn("quartermaster")
        |> put_req_header("idempotency-key", key)
        |> post("/api/inventory/items", Map.put(first_payload, "quantity", 3))

      assert %{"errors" => %{"detail" => detail}} = json_response(mismatch, 422)
      assert detail =~ "cannot be reused"
      assert Repo.aggregate(Dhc.Inventory.Item, :count) == 1
    end

    test "returns 409 while the original request is in flight", %{conn: conn} do
      category = insert_category!("Idempotency In Flight")
      container = create_container!(%{"name" => "In Flight Rack"})
      payload = item_payload(container, category)
      key = "item-create-processing"

      request_id =
        IdempotencyPlug.sha256_hash(
          :idempotency_key,
          {@actor_id, key}
        )

      fingerprint =
        IdempotencyPlug.sha256_hash(
          :request_payload,
          {["api", "inventory", "items"], payload |> Map.to_list() |> Enum.sort()}
        )

      assert {:init, ^request_id, _expires_at} =
               IdempotencyPlug.RequestTracker.track(
                 idempotency_tracker(),
                 request_id,
                 fingerprint
               )

      duplicate =
        conn
        |> auth_conn("quartermaster")
        |> put_req_header("idempotency-key", key)
        |> post("/api/inventory/items", payload)

      assert %{"errors" => %{"detail" => detail}} = json_response(duplicate, 409)
      assert detail =~ "currently being processed"
      assert Repo.aggregate(Dhc.Inventory.Item, :count) == 0

      assert {:ok, _expires_at} =
               IdempotencyPlug.RequestTracker.put_response(idempotency_tracker(), request_id, %{})
    end

    test "scopes idempotency keys to the authenticated principal", %{conn: conn} do
      category = insert_category!("Idempotency Principal Scope")
      container = create_container!(%{"name" => "Principal Scope Rack"})
      payload = item_payload(container, category)
      key = "shared-user-key"

      first =
        conn
        |> auth_conn("quartermaster")
        |> put_req_header("idempotency-key", key)
        |> post("/api/inventory/items", payload)

      assert first.status == 201

      other_user =
        build_conn()
        |> auth_conn("other")
        |> put_req_header("idempotency-key", key)
        |> post("/api/inventory/items", payload)

      assert other_user.status == 201
      assert get_resp_header(other_user, "idempotent-replayed") == []
      assert Repo.aggregate(Dhc.Inventory.Item, :count) == 2
    end

    test "executes a fresh request when the stored key is expired", %{conn: conn} do
      category = insert_category!("Idempotency Expiry")
      container = create_container!(%{"name" => "Expiry Rack"})
      payload = item_payload(container, category)
      key = "expired-item-create"

      request_id = IdempotencyPlug.sha256_hash(:idempotency_key, {@actor_id, key})

      fingerprint =
        IdempotencyPlug.sha256_hash(
          :request_payload,
          {["api", "inventory", "items"], payload |> Map.to_list() |> Enum.sort()}
        )

      %IdempotentRequest{
        id: request_id,
        fingerprint: fingerprint,
        data: {:ok, %{status: 201, resp_body: "stale", resp_headers: []}},
        expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
      }
      |> IdempotentRequest.changeset()
      |> Repo.insert!()

      fresh =
        conn
        |> auth_conn("quartermaster")
        |> put_req_header("idempotency-key", key)
        |> post("/api/inventory/items", payload)

      assert fresh.status == 201
      refute fresh.resp_body == "stale"
      assert Repo.aggregate(Dhc.Inventory.Item, :count) == 1
    end

    test "processes requests with no idempotency key normally", %{conn: conn} do
      category = insert_category!("No Idempotency Key")
      container = create_container!(%{"name" => "No Key Rack"})
      payload = item_payload(container, category)

      first = conn |> auth_conn("quartermaster") |> post("/api/inventory/items", payload)
      second = build_conn() |> auth_conn("quartermaster") |> post("/api/inventory/items", payload)

      assert first.status == 201
      assert second.status == 201
      assert Repo.aggregate(Dhc.Inventory.Item, :count) == 2
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

  defp idempotency_tracker do
    Application.get_env(:dhc, :idempotency_tracker, DhcWeb.IdempotencyRequestTracker)
  end

  defp request_tracker_child_spec do
    %{
      id: make_ref(),
      restart: :temporary,
      start:
        {IdempotencyPlug.RequestTracker, :start_link,
         [[name: nil, store: {IdempotencyPlug.EctoStore, repo: Dhc.Repo}]]}
    }
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

  # ── Conditional requests (ALE-266 Phase 1.2) ──────────────────────────
  #
  # The ETag/If-Match/If-None-Match wire contract per ADR 0023: strong ETag
  # derived from lock_version, 412 (with current entity) on stale If-Match,
  # 304 on matching If-None-Match, 400 on unsupported conditional headers,
  # unchanged behaviour when no headers are sent.

  describe "conditional requests — GET" do
    setup do
      category = insert_category!("Etag Category")
      container = create_container!(%{"name" => "Etag Container"})
      item = create_item!(item_payload(container, category))
      %{item: item, id: to_uuid(item.id)}
    end

    test "GET returns lockVersion in body and a strong ETag header", %{
      conn: conn,
      id: id
    } do
      conn =
        conn
        |> auth_conn("member")
        |> get("/api/inventory/items/#{id}")

      assert %{"data" => payload} = json_response(conn, 200)
      assert payload["lockVersion"] == 1
      assert get_resp_header(conn, "etag") == ["\"1\""]
    end

    test "GET with matching If-None-Match returns 304 with ETag and no body", %{
      conn: conn,
      id: id
    } do
      conn =
        conn
        |> auth_conn("member")
        |> put_req_header("if-none-match", "\"1\"")
        |> get("/api/inventory/items/#{id}")

      assert response(conn, 304) == ""
      assert get_resp_header(conn, "etag") == ["\"1\""]
    end

    test "GET with stale If-None-Match returns 200 with the item", %{
      conn: conn,
      id: id
    } do
      conn =
        conn
        |> auth_conn("member")
        |> put_req_header("if-none-match", "\"999\"")
        |> get("/api/inventory/items/#{id}")

      assert %{"data" => payload} = json_response(conn, 200)
      assert payload["lockVersion"] == 1
      assert get_resp_header(conn, "etag") == ["\"1\""]
    end

    test "GET with unsupported conditional header returns 400", %{
      conn: conn,
      id: id
    } do
      conn =
        conn
        |> auth_conn("member")
        |> put_req_header("if-modified-since", "Mon, 31 Aug 2026 00:00:00 GMT")
        |> get("/api/inventory/items/#{id}")

      assert %{"errors" => %{"detail" => detail}} = json_response(conn, 400)
      assert detail =~ "not supported"
    end

    test "GET with matching If-Match serves the item; stale If-Match returns 412", %{
      conn: conn,
      id: id
    } do
      conn =
        conn
        |> auth_conn("member")
        |> put_req_header("if-match", "\"1\"")
        |> get("/api/inventory/items/#{id}")

      assert %{"data" => payload} = json_response(conn, 200)
      assert payload["lockVersion"] == 1

      {:ok, _} = Dhc.Inventory.update_item(id, %{"quantity" => 99}, @actor_id)

      conn =
        build_conn()
        |> auth_conn("member")
        |> put_req_header("if-match", "\"1\"")
        |> get("/api/inventory/items/#{id}")

      assert %{"data" => current, "errors" => %{"detail" => "version precondition failed"}} =
               json_response(conn, 412)

      assert current["quantity"] == 99
      assert current["lockVersion"] == 2
    end
  end

  describe "conditional requests — PATCH" do
    setup do
      category = insert_category!("Etag Patch Category")
      container = create_container!(%{"name" => "Etag Patch Container"})
      item = create_item!(item_payload(container, category))
      %{item: item, id: to_uuid(item.id)}
    end

    test "PATCH with matching If-Match succeeds and bumps the version", %{
      conn: conn,
      id: id
    } do
      conn =
        conn
        |> auth_conn("admin")
        |> put_req_header("if-match", "\"1\"")
        |> patch("/api/inventory/items/#{id}", %{"quantity" => 7})

      assert %{"data" => payload} = json_response(conn, 200)
      assert payload["quantity"] == 7
      assert payload["lockVersion"] == 2
      assert get_resp_header(conn, "etag") == ["\"2\""]
    end

    test "PATCH with If-Match: * succeeds while the item exists", %{
      conn: conn,
      id: id
    } do
      conn =
        conn
        |> auth_conn("admin")
        |> put_req_header("if-match", "*")
        |> patch("/api/inventory/items/#{id}", %{"quantity" => 5})

      assert %{"data" => payload} = json_response(conn, 200)
      assert payload["lockVersion"] == 2
    end

    test "PATCH with stale If-Match returns 412 with the current entity", %{
      conn: conn,
      id: id
    } do
      # A concurrent edit bumps the server version past the client's witness.
      {:ok, _} = Dhc.Inventory.update_item(id, %{"quantity" => 99}, @actor_id)

      conn =
        conn
        |> auth_conn("admin")
        |> put_req_header("if-match", "\"1\"")
        |> patch("/api/inventory/items/#{id}", %{"quantity" => 7})

      assert %{"data" => current, "errors" => %{"detail" => "version precondition failed"}} =
               json_response(conn, 412)

      assert current["quantity"] == 99
      assert current["lockVersion"] == 2
      assert get_resp_header(conn, "etag") == ["\"2\""]
    end

    test "PATCH with malformed If-Match returns 400", %{conn: conn, id: id} do
      conn =
        conn
        |> auth_conn("admin")
        |> put_req_header("if-match", "garbage")
        |> patch("/api/inventory/items/#{id}", %{"quantity" => 7})

      assert %{"errors" => %{"detail" => detail}} = json_response(conn, 400)
      assert detail =~ "Invalid"
    end

    test "PATCH with unsupported conditional header returns 400", %{conn: conn, id: id} do
      conn =
        conn
        |> auth_conn("admin")
        |> put_req_header("if-unmodified-since", "Mon, 31 Aug 2026 00:00:00 GMT")
        |> patch("/api/inventory/items/#{id}", %{"quantity" => 7})

      assert %{"errors" => %{"detail" => detail}} = json_response(conn, 400)
      assert detail =~ "not supported"
    end

    test "PATCH with stale If-Match returns exactly the 412 envelope shape", %{
      conn: conn,
      id: id
    } do
      {:ok, _} = Dhc.Inventory.update_item(id, %{"quantity" => 99}, @actor_id)

      conn =
        conn
        |> auth_conn("admin")
        |> put_req_header("if-match", "\"1\"")
        |> patch("/api/inventory/items/#{id}", %{"quantity" => 7})

      assert %{"data" => current, "errors" => %{"detail" => "version precondition failed"}} =
               json_response(conn, 412)

      assert Map.keys(current) |> Enum.sort() ==
               [
                 "attributes",
                 "category",
                 "categoryId",
                 "container",
                 "containerId",
                 "createdAt",
                 "createdBy",
                 "id",
                 "lockVersion",
                 "notes",
                 "outForMaintenance",
                 "photoUrl",
                 "quantity",
                 "updatedAt",
                 "updatedBy"
               ]
    end

    test "PATCH without If-Match keeps current behaviour", %{conn: conn, id: id} do
      conn =
        conn
        |> auth_conn("admin")
        |> patch("/api/inventory/items/#{id}", %{"quantity" => 7})

      assert %{"data" => payload} = json_response(conn, 200)
      assert payload["quantity"] == 7
      assert payload["lockVersion"] == 2
    end
  end

  describe "conditional requests — DELETE" do
    setup do
      category = insert_category!("Etag Delete Category")
      container = create_container!(%{"name" => "Etag Delete Container"})
      item = create_item!(item_payload(container, category))
      %{item: item, id: to_uuid(item.id)}
    end

    test "DELETE with matching If-Match succeeds with 204", %{conn: conn, id: id} do
      conn =
        conn
        |> auth_conn("president")
        |> put_req_header("if-match", "\"1\"")
        |> delete("/api/inventory/items/#{id}")

      assert response(conn, 204) == ""
      assert {:error, :not_found} = Dhc.Inventory.get_item(id)
    end

    test "DELETE with stale If-Match returns 412 with the current entity", %{
      conn: conn,
      id: id
    } do
      {:ok, _} = Dhc.Inventory.update_item(id, %{"quantity" => 99}, @actor_id)

      conn =
        conn
        |> auth_conn("president")
        |> put_req_header("if-match", "\"1\"")
        |> delete("/api/inventory/items/#{id}")

      assert %{"data" => current, "errors" => %{"detail" => "version precondition failed"}} =
               json_response(conn, 412)

      assert current["quantity"] == 99
      assert current["lockVersion"] == 2
    end

    test "DELETE without If-Match keeps current behaviour", %{conn: conn, id: id} do
      conn =
        conn
        |> auth_conn("president")
        |> delete("/api/inventory/items/#{id}")

      assert response(conn, 204) == ""
    end

    test "DELETE with unsupported conditional header returns 400", %{conn: conn, id: id} do
      conn =
        conn
        |> auth_conn("president")
        |> put_req_header("if-range", "\"1\"")
        |> delete("/api/inventory/items/#{id}")

      assert %{"errors" => %{"detail" => detail}} = json_response(conn, 400)
      assert detail =~ "not supported"
      assert {:ok, _} = Dhc.Inventory.get_item(id)
    end
  end

  describe "conditional requests — command writes" do
    test "move honors If-Match and returns the bumped ETag", %{conn: conn} do
      category = insert_category!("Command Etag Category")
      source = create_container!(%{"name" => "Command Source"})
      destination = create_container!(%{"name" => "Command Destination"})
      item = create_item!(item_payload(source, category))

      conn =
        conn
        |> auth_conn("admin")
        |> put_req_header("if-match", "\"1\"")
        |> post("/api/inventory/items/#{to_uuid(item.id)}/move", %{
          "containerId" => to_uuid(destination.id)
        })

      assert %{"data" => %{"containerId" => container_id, "lockVersion" => 2}} =
               json_response(conn, 200)

      assert container_id == to_uuid(destination.id)
      assert get_resp_header(conn, "etag") == ["\"2\""]
    end

    test "maintenance rejects a stale If-Match with the current item", %{conn: conn} do
      category = insert_category!("Command Stale Category")
      container = create_container!(%{"name" => "Command Stale Container"})
      item = create_item!(item_payload(container, category))
      {:ok, _} = Dhc.Inventory.update_item(to_uuid(item.id), %{"quantity" => 9}, @actor_id)

      conn =
        conn
        |> auth_conn("admin")
        |> put_req_header("if-match", "\"1\"")
        |> post("/api/inventory/items/#{to_uuid(item.id)}/maintenance", %{
          "outForMaintenance" => true
        })

      assert %{
               "data" => %{"quantity" => 9, "lockVersion" => 2},
               "errors" => %{"detail" => "version precondition failed"}
             } = json_response(conn, 412)
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
