defmodule DhcWeb.InventoryOperatorLoanQueueControllerTest do
  @moduledoc """
  Request/contract tests for ALE-298 (ALE-286c) operator loan queue exposure.

  The queue is unpaginated by design: each bucket is `{count, rows}` where
  `count` is `length(rows)`. Domain partitioning lives in
  `Dhc.Inventory.OperatorLoanQueueTest`; this suite proves the HTTP
  envelope, role gates, and that a queue row is the same projection as
  the operator loan show.
  """

  use DhcWeb.ConnCase, async: false

  alias Dhc.Inventory
  alias Dhc.ClubCalendar
  alias DhcWeb.OpenApiVerifier

  @actor_id "66666666-6666-6666-6666-666666666666"
  @write_roles ~w(quartermaster admin president)

  setup do
    original =
      OpenApiVerifier.install(
        actor_id: @actor_id,
        roles: ~w(quartermaster admin president member)
      )

    {:ok, _} = Dhc.Auth.register_principal_with_id(@actor_id, %{email: "op-queue@example.com"})

    on_exit(fn -> OpenApiVerifier.restore(original) end)

    :ok
  end

  defp auth_conn(conn, role), do: put_req_header(conn, "authorization", "Bearer #{role}-token")

  describe "show" do
    test "returns the four-bucket envelope", %{conn: conn} do
      %{item: item} = fixture()
      {:ok, request} = request(item)

      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/operator/loans/queue")

      assert %{"data" => data} = json_response(conn, 200)

      assert Enum.sort(Map.keys(data)) ==
               Enum.sort(~w(pendingRequests handoversDue returnsAndOverdue openMaintenance))

      assert %{"count" => 1, "rows" => [%{"id" => id}]} = data["pendingRequests"]
      assert id == request.id
    end

    test "grants every operator role equal read authority and 401s without a session", %{
      conn: conn
    } do
      for role <- @write_roles do
        read = build_conn() |> auth_conn(role) |> get("/api/inventory/operator/loans/queue")
        assert %{"data" => _} = json_response(read, 200)
      end

      anonymous = get(conn, "/api/inventory/operator/loans/queue")
      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(anonymous, 401)
    end

    test "refuses members", %{conn: conn} do
      blocked = conn |> auth_conn("member") |> get("/api/inventory/operator/loans/queue")
      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(blocked, 403)
    end
  end

  describe "openapi operator loan queue contract" do
    test "the queue operation lives on the one Inventory tag and is unpaginated" do
      spec = load_openapi_spec!()
      operation = get_in(spec, ["paths", "/inventory/operator/loans/queue", "get"])

      assert operation["operationId"] == "inventoryOperatorLoanQueue.show"
      assert operation["tags"] == ["Inventory"]
      assert operation["security"] == [%{"cookieSession" => []}]
      refute Map.has_key?(operation, "parameters")

      queue = get_in(spec, ["components", "schemas", "InventoryOperatorLoanQueue"])

      assert Enum.sort(Map.keys(queue["properties"])) ==
               Enum.sort(~w(pendingRequests handoversDue returnsAndOverdue openMaintenance))
    end
  end

  # ── Fixtures ────────────────────────────────────────────────────

  defp fixture do
    {:ok, category} =
      Inventory.create_category(%{
        "name" => "Op queue cat #{System.unique_integer([:positive])}"
      })

    {:ok, container} =
      Inventory.create_container(
        %{"name" => "Op queue bin #{System.unique_integer([:positive])}"},
        @actor_id
      )

    {:ok, item} =
      Inventory.create_operator_item(
        %{"container_id" => container.id, "category_id" => category.id},
        @actor_id
      )

    %{item: item}
  end

  defp request(item) do
    borrower_id = Ecto.UUID.generate()

    {:ok, _} =
      Dhc.Auth.register_principal_with_id(borrower_id, %{
        email: "q-borrower-#{System.unique_integer([:positive])}@example.com"
      })

    today = ClubCalendar.today()

    Inventory.request_loan(
      item.slug,
      %{
        "startsOn" => Date.to_iso8601(today),
        "dueOn" => Date.to_iso8601(Date.add(today, 7))
      },
      borrower_id
    )
  end

  defp load_openapi_spec! do
    path = Application.app_dir(:dhc, "priv/api/openapi.yaml")

    case YamlElixir.read_from_file(path) do
      {:ok, spec} -> spec
      {:error, error} -> flunk("failed to parse OpenAPI spec: #{inspect(error)}")
    end
  end
end
