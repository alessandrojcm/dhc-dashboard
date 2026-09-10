defmodule DhcWeb.InventoryCatalogControllerTest do
  @moduledoc """
  Request/contract tests for the ALE-285 member catalog and request command.

  The privacy contract is the centre of this suite: the member payload is
  asserted by its **complete** key set, so a field added to the renderer
  cannot quietly start leaking the container, operator notes, maintenance
  facts, or archive state (spec ALE-280 story 45). Alongside that: the
  generic availability reason, slug-or-id resolution, cursor pagination with
  exact counts, the search and filter parameters, and the typed error mapping
  for unavailable items and duplicate requests.

  Domain invariants live in `Dhc.Inventory.MemberCatalogTest` and
  `Dhc.Inventory.MemberLoansTest`.
  """

  use DhcWeb.ConnCase, async: false

  alias Dhc.Inventory
  alias Dhc.Inventory.ClubCalendar

  @actor_id "33333333-3333-3333-3333-333333333333"

  defmodule Verifier do
    @actor_id "33333333-3333-3333-3333-333333333333"

    for role <- ~w(member quartermaster admin president) do
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

    {:ok, _} = Dhc.Auth.register_principal_with_id(@actor_id, %{email: "catalog@example.com"})

    on_exit(fn -> Application.put_env(:dhc, :auth_verifier, original) end)

    :ok
  end

  defp auth_conn(conn, role), do: put_req_header(conn, "authorization", "Bearer #{role}-token")

  # ── Privacy and shape ───────────────────────────────────────────

  describe "member payload" do
    test "carries only the member-entitled fields", %{conn: conn} do
      %{category: category, container_id: container_id} = fixture()
      {:ok, brand} = definition(category.id, "Brand", "text", identifying_position: 0)

      {:ok, item} =
        Inventory.create_operator_item(
          %{
            "container_id" => container_id,
            "category_id" => category.id,
            "notes" => "Operator-only remark",
            "values" => %{brand.id => "Regenyei"}
          },
          @actor_id
        )

      conn = conn |> auth_conn("member") |> get("/api/inventory/catalog/items/#{item.slug}")

      assert %{"data" => payload} = json_response(conn, 200)

      # The complete key set is the contract: no container, notes,
      # maintenance, archive state, or actor ids may ever appear.
      assert Enum.sort(Map.keys(payload)) ==
               Enum.sort(~w(id slug label category values availability))

      assert payload["slug"] == item.slug
      assert payload["label"] == "#{category.name} · Regenyei"
      assert payload["category"] == %{"id" => category.id, "name" => category.name}
      assert payload["availability"] == %{"available" => true, "reason" => "available"}

      assert [value] = payload["values"]
      assert value["definitionLabel"] == "Brand"
      assert value["text"] == "Regenyei"
      assert value["identifyingPosition"] == 0
    end

    test "reports an unavailable item with a generic reason only", %{conn: conn} do
      %{category: category, container_id: container_id} = fixture()
      {:ok, serviced} = create_item(container_id, category.id)
      {:ok, borrowed} = create_item(container_id, category.id)
      borrower = principal!("borrower")

      assert {:ok, _} =
               Inventory.start_operator_item_maintenance(
                 serviced.slug,
                 %{"reason" => "Blade bent in sparring"},
                 @actor_id
               )

      create_loan!(borrowed, borrower, "checked_out")

      conn = conn |> auth_conn("member") |> get("/api/inventory/catalog/items")
      assert %{"data" => data} = json_response(conn, 200)

      by_id = Map.new(data["items"], &{&1["id"], &1})

      assert by_id[serviced.id]["availability"] ==
               %{"available" => false, "reason" => "maintenance"}

      assert by_id[borrowed.id]["availability"] == %{"available" => false, "reason" => "on_loan"}

      # Neither the borrower nor the maintenance reason may appear anywhere.
      body = Jason.encode!(data)
      refute body =~ borrower
      refute body =~ "bent"
    end

    test "hides archived items with no filter to opt into", %{conn: conn} do
      %{category: category, container_id: container_id} = fixture()
      {:ok, active} = create_item(container_id, category.id)
      {:ok, retired} = create_item(container_id, category.id)

      assert {:ok, _} = Inventory.archive_operator_item(retired.slug, %{}, @actor_id)

      listed =
        conn
        |> auth_conn("member")
        |> get("/api/inventory/catalog/items", %{"archived" => "only"})

      assert %{"data" => data} = json_response(listed, 200)
      assert Enum.map(data["items"], & &1["id"]) == [active.id]

      # Resolving an archived item is a plain 404: "archived" is an operator
      # fact about an item the member cannot see.
      missing =
        build_conn()
        |> auth_conn("member")
        |> get("/api/inventory/catalog/items/#{retired.slug}")

      assert %{"errors" => %{"detail" => "Item not found"}} = json_response(missing, 404)
    end
  end

  # ── Access ──────────────────────────────────────────────────────

  describe "access" do
    test "any authenticated member may browse, and anonymous callers may not", %{conn: conn} do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      for role <- ~w(member quartermaster admin president) do
        listed = build_conn() |> auth_conn(role) |> get("/api/inventory/catalog/items")
        assert %{"data" => _} = json_response(listed, 200)
      end

      anonymous = get(conn, "/api/inventory/catalog/items")
      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(anonymous, 401)

      anonymous_show = get(build_conn(), "/api/inventory/catalog/items/#{item.slug}")
      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(anonymous_show, 401)

      anonymous_request =
        post(build_conn(), "/api/inventory/catalog/items/#{item.slug}/requests", %{})

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(anonymous_request, 401)
    end
  end

  # ── Browse ──────────────────────────────────────────────────────

  describe "list" do
    test "pages with exact totalCount and cursor metadata", %{conn: conn} do
      %{category: category, container_id: container_id} = fixture()

      slugs =
        for _ <- 1..12 do
          {:ok, item} = create_item(container_id, category.id)
          item.slug
        end

      sorted = Enum.sort(slugs)

      first =
        conn |> auth_conn("member") |> get("/api/inventory/catalog/items", %{"limit" => "10"})

      assert %{"data" => data} = json_response(first, 200)
      assert Enum.map(data["items"], & &1["slug"]) == Enum.take(sorted, 10)
      assert data["totalCount"] == 12
      assert data["limit"] == 10
      assert is_binary(data["nextCursor"])
      assert data["previousCursor"] == nil

      second =
        build_conn()
        |> auth_conn("member")
        |> get("/api/inventory/catalog/items", %{
          "limit" => "10",
          "cursor" => data["nextCursor"]
        })

      assert %{"data" => page_two} = json_response(second, 200)
      assert Enum.map(page_two["items"], & &1["slug"]) == Enum.drop(sorted, 10)
      assert page_two["totalCount"] == 12
      assert page_two["nextCursor"] == nil
    end

    test "searches and filters", %{conn: conn} do
      %{category: category, container_id: container_id} = fixture()
      other_category = create_category!()
      {:ok, brand} = definition(category.id, "Brand", "text")

      {:ok, regenyei} = create_item(container_id, category.id, %{brand.id => "Regenyei"})
      {:ok, _darkwood} = create_item(container_id, category.id, %{brand.id => "Darkwood"})
      {:ok, mask} = create_item(container_id, other_category.id)

      searched =
        conn |> auth_conn("member") |> get("/api/inventory/catalog/items", %{"q" => "regen"})

      assert %{"data" => search_data} = json_response(searched, 200)
      assert Enum.map(search_data["items"], & &1["id"]) == [regenyei.id]

      filtered =
        build_conn()
        |> auth_conn("member")
        |> get("/api/inventory/catalog/items", %{"categoryId" => other_category.id})

      assert %{"data" => filter_data} = json_response(filtered, 200)
      assert Enum.map(filter_data["items"], & &1["id"]) == [mask.id]

      by_property =
        build_conn()
        |> auth_conn("member")
        |> get("/api/inventory/catalog/items", %{"property" => "#{brand.id}:Regenyei"})

      assert %{"data" => property_data} = json_response(by_property, 200)
      assert Enum.map(property_data["items"], & &1["id"]) == [regenyei.id]
    end

    test "answers 400 for a bad parameter or mismatched cursor", %{conn: conn} do
      bad_limit =
        conn |> auth_conn("member") |> get("/api/inventory/catalog/items", %{"limit" => "7"})

      assert %{"errors" => %{"detail" => detail}} = json_response(bad_limit, 400)
      assert detail =~ "limit"

      bad_cursor =
        build_conn()
        |> auth_conn("member")
        |> get("/api/inventory/catalog/items", %{"cursor" => "not-a-cursor"})

      assert %{"errors" => %{"detail" => cursor_detail}} = json_response(bad_cursor, 400)
      assert cursor_detail =~ "cursor"

      bad_category =
        build_conn()
        |> auth_conn("member")
        |> get("/api/inventory/catalog/items", %{"categoryId" => "not-a-uuid"})

      assert %{"errors" => %{"detail" => category_detail}} = json_response(bad_category, 400)
      assert category_detail =~ "categoryId"
    end
  end

  describe "show" do
    test "resolves by slug or id and 404s otherwise", %{conn: conn} do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)

      by_slug = conn |> auth_conn("member") |> get("/api/inventory/catalog/items/#{item.slug}")
      assert json_response(by_slug, 200)["data"]["id"] == item.id

      by_id =
        build_conn() |> auth_conn("member") |> get("/api/inventory/catalog/items/#{item.id}")

      assert json_response(by_id, 200)["data"]["slug"] == item.slug

      missing =
        build_conn() |> auth_conn("member") |> get("/api/inventory/catalog/items/item-999999")

      assert %{"errors" => %{"detail" => "Item not found"}} = json_response(missing, 404)
    end
  end

  # ── Request ─────────────────────────────────────────────────────

  describe "request" do
    test "creates a request for the caller and returns the member loan shape", %{conn: conn} do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)
      today = ClubCalendar.today()

      conn =
        conn
        |> auth_conn("member")
        |> post("/api/inventory/catalog/items/#{item.slug}/requests", %{
          "startsOn" => Date.to_iso8601(today),
          "dueOn" => Date.to_iso8601(Date.add(today, 7)),
          "note" => "For Saturday"
        })

      assert %{"data" => loan} = json_response(conn, 201)

      assert loan["status"] == "requested"
      assert loan["itemId"] == item.id
      assert loan["itemSlug"] == item.slug
      assert loan["requestNote"] == "For Saturday"
      assert loan["requestedStartOn"] == Date.to_iso8601(today)
      assert loan["overdue"] == false

      # No entitlement yet, so no container path (story 15) and no borrower
      # field at all.
      assert loan["containerPath"] == nil
      refute Map.has_key?(loan, "borrowerPrincipalId")
    end

    test "answers 409 with a generic code for an unavailable item", %{conn: conn} do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)
      today = Date.to_iso8601(ClubCalendar.today())

      assert {:ok, _} =
               Inventory.start_operator_item_maintenance(
                 item.slug,
                 %{"reason" => "Blade bent"},
                 @actor_id
               )

      conn =
        conn
        |> auth_conn("member")
        |> post("/api/inventory/catalog/items/#{item.slug}/requests", %{
          "startsOn" => today,
          "dueOn" => today
        })

      assert %{"errors" => errors} = json_response(conn, 409)
      assert errors["code"] == "item_unavailable"
      # The detail must not explain what is wrong with the item.
      refute errors["detail"] =~ "bent"
      refute errors["detail"] =~ "maintenance"
    end

    test "answers 409 for a second pending request from the same member", %{conn: conn} do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)
      today = Date.to_iso8601(ClubCalendar.today())
      body = %{"startsOn" => today, "dueOn" => today}

      first =
        conn
        |> auth_conn("member")
        |> post("/api/inventory/catalog/items/#{item.slug}/requests", body)

      assert json_response(first, 201)

      second =
        build_conn()
        |> auth_conn("member")
        |> post("/api/inventory/catalog/items/#{item.slug}/requests", body)

      assert %{"errors" => %{"code" => "duplicate_request"}} = json_response(second, 409)
    end

    test "answers 422 for bad dates and 404 for an unknown item", %{conn: conn} do
      %{category: category, container_id: container_id} = fixture()
      {:ok, item} = create_item(container_id, category.id)
      today = ClubCalendar.today()

      past =
        conn
        |> auth_conn("member")
        |> post("/api/inventory/catalog/items/#{item.slug}/requests", %{
          "startsOn" => Date.to_iso8601(Date.add(today, -1)),
          "dueOn" => Date.to_iso8601(today)
        })

      assert %{"errors" => %{"code" => "invalid_dates"}} = json_response(past, 422)

      inverted =
        build_conn()
        |> auth_conn("member")
        |> post("/api/inventory/catalog/items/#{item.slug}/requests", %{
          "startsOn" => Date.to_iso8601(Date.add(today, 5)),
          "dueOn" => Date.to_iso8601(today)
        })

      assert %{"errors" => %{"code" => "invalid_dates"}} = json_response(inverted, 422)

      missing =
        build_conn()
        |> auth_conn("member")
        |> post("/api/inventory/catalog/items/item-999999/requests", %{
          "startsOn" => Date.to_iso8601(today),
          "dueOn" => Date.to_iso8601(today)
        })

      assert %{"errors" => %{"detail" => "Item not found"}} = json_response(missing, 404)
    end
  end

  # ── Fixtures ────────────────────────────────────────────────────

  defp fixture do
    %{category: create_category!(), container_id: create_container!().id}
  end

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
        {:identifying_position, position}, acc -> Map.put(acc, "identifying_position", position)
      end)

    Inventory.create_definition(category_id, attrs)
  end

  defp create_category! do
    {:ok, category} =
      Inventory.create_category(%{
        "name" => "Catalog HTTP category #{System.unique_integer([:positive])}"
      })

    category
  end

  defp create_container! do
    {:ok, container} =
      Inventory.create_container(
        %{"name" => "Catalog HTTP container #{System.unique_integer([:positive])}"},
        @actor_id
      )

    container
  end

  defp principal!(prefix) do
    id = Ecto.UUID.generate()

    {:ok, _} =
      Dhc.Auth.register_principal_with_id(id, %{
        email: "#{prefix}-#{System.unique_integer([:positive])}@example.com"
      })

    id
  end

  # Loan rows are fixtures for the catalog read; operator transitions are
  # ALE-286.
  defp create_loan!(item, borrower_id, status) do
    %{rows: [[loan_id]]} =
      Dhc.Repo.query!(
        """
        INSERT INTO inventory_loans (
          item_id, borrower_principal_id, status,
          requested_start_on, requested_due_on,
          item_slug_snapshot, item_label_snapshot,
          created_at, updated_at
        )
        VALUES ($1, $2, $3, CURRENT_DATE, CURRENT_DATE + 7, $4, $5, NOW(), NOW())
        RETURNING id
        """,
        [
          Ecto.UUID.dump!(item.id),
          Ecto.UUID.dump!(borrower_id),
          status,
          item.slug,
          item.label || item.slug
        ]
      )

    Ecto.UUID.load!(loan_id)
  end
end
