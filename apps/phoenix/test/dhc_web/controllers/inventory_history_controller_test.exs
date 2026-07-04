defmodule DhcWeb.InventoryHistoryControllerTest do
  @moduledoc """
  Request/contract tests for the global inventory activity feed — ALE-108.

  Covers `GET /inventory/history`: any authenticated member may read, the feed
  is newest-first across all items, each row carries `oldContainer`/
  `newContainer` name summaries and an `item` summary (`%{id, attributes}`),
  and the `limit` query param is honored. Includes maintenance_out/
  maintenance_in rows surfaced through the global feed.
  """

  use DhcWeb.ConnCase, async: false

  alias Dhc.Repo

  @actor_id "11111111-1111-1111-1111-111111111111"
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

    insert_user!(@actor_id, "inv-history-actor@example.com")

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

  describe "index" do
    test "returns global activity newest first with item and container summaries", %{
      conn: conn
    } do
      category = insert_category!("ALE108 Global Feed")
      old = create_container!(%{"name" => "Old Global"})
      new = create_container!(%{"name" => "New Global"})
      item = create_item!(item_payload(old, category))

      {:ok, _} =
        Dhc.Inventory.move_item(
          to_uuid(item.id),
          %{"containerId" => to_uuid(new.id), "notes" => "global move"},
          @actor_id
        )

      {:ok, _} =
        Dhc.Inventory.set_item_maintenance(
          to_uuid(item.id),
          %{"outForMaintenance" => true, "notes" => "broken strap"},
          @actor_id
        )

      conn =
        conn
        |> auth_conn("member")
        |> get("/api/inventory/history", %{"limit" => "10"})

      assert %{"data" => %{"history" => history, "limit" => 10}} = json_response(conn, 200)

      actions = Enum.map(history, & &1["action"])
      assert "maintenance_out" in actions
      assert "moved" in actions
      assert "created" in actions

      # Newest first: maintenance_out before moved before created.
      assert Enum.find_index(actions, &(&1 == "maintenance_out")) <
               Enum.find_index(actions, &(&1 == "moved"))

      moved = Enum.find(history, &(&1["action"] == "moved"))
      assert moved["oldContainer"] == %{"id" => to_uuid(old.id), "name" => "Old Global"}
      assert moved["newContainer"] == %{"id" => to_uuid(new.id), "name" => "New Global"}
      assert moved["notes"] == "global move"

      # The global feed carries the item summary so the UI can render a
      # display name without a second lookup.
      assert moved["item"]["id"] == to_uuid(item.id)
      assert moved["item"]["attributes"]["name"] == "Longsword"

      maint = Enum.find(history, &(&1["action"] == "maintenance_out"))
      assert maint["item"]["id"] == to_uuid(item.id)
      assert maint["notes"] == "broken strap"
      # Maintenance rows carry no container change.
      assert maint["oldContainer"] == nil
      assert maint["newContainer"] == nil
    end

    test "honors the limit query param", %{conn: conn} do
      category = insert_category!("ALE108 Limit Feed")
      container = create_container!(%{"name" => "Limit Box"})

      for n <- 1..5 do
        create_item!(item_payload(container, category, %{"notes" => "item #{n}"}))
      end

      conn =
        conn
        |> auth_conn("member")
        |> get("/api/inventory/history", %{"limit" => "3"})

      assert %{"data" => %{"history" => history, "limit" => 3}} = json_response(conn, 200)
      assert length(history) <= 3
    end

    test "defaults to limit 50 when no limit param is passed", %{conn: conn} do
      conn =
        conn
        |> auth_conn("member")
        |> get("/api/inventory/history")

      assert %{"data" => %{"history" => _history, "limit" => 50}} = json_response(conn, 200)
    end

    test "returns 401 without auth", %{conn: conn} do
      conn = get(conn, "/api/inventory/history")
      assert json_response(conn, 401)
    end
  end

  test "read endpoints allow authenticated roles", %{conn: _conn} do
    category = insert_category!("ALE108 History Read Roles")
    container = create_container!(%{"name" => "Read Box"})
    create_item!(item_payload(container, category))

    for role <- @read_roles do
      assert %{"data" => _} =
               build_conn()
               |> auth_conn(role)
               |> get("/api/inventory/history")
               |> json_response(200)
    end
  end
end
