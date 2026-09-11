defmodule DhcWeb.InventoryOperatorLoansControllerTest do
  @moduledoc """
  Request/contract tests for ALE-298 (ALE-286c) operator loan viewers and
  commands.

  Covers the operator-shaped payload (borrower, dates, actual timestamps,
  notes, item snapshot, container path — and no member-only omissions),
  command-specific requests (no generic loan patch), role gates with equal
  quartermaster/president/admin authority, typed 409/422 mapping, and the
  post-commit keyed notifications on approve / reject / cancel / date
  change.

  Domain invariants live in `Dhc.Inventory.OperatorLoansTest`. Queue
  exposure lives in `DhcWeb.InventoryOperatorLoanQueueControllerTest`.
  """

  use DhcWeb.ConnCase, async: false

  alias Dhc.Inventory
  alias Dhc.Inventory.ClubCalendar
  alias Dhc.Notifications.Notification
  alias Dhc.Repo

  @actor_id "55555555-5555-5555-5555-555555555555"
  @write_roles ~w(quartermaster admin president)

  defmodule Verifier do
    @actor_id "55555555-5555-5555-5555-555555555555"

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

    {:ok, _} = Dhc.Auth.register_principal_with_id(@actor_id, %{email: "op-loans@example.com"})

    on_exit(fn -> Application.put_env(:dhc, :auth_verifier, original) end)

    :ok
  end

  defp auth_conn(conn, role), do: put_req_header(conn, "authorization", "Bearer #{role}-token")

  # ── Show: viewer shape and role gates ───────────────────────────

  describe "show" do
    test "returns the operator viewer with borrower and container path", %{conn: conn} do
      %{loan: loan} = approved_loan()

      conn =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/operator/loans/#{loan.id}")

      assert %{"data" => payload} = json_response(conn, 200)

      assert Enum.sort(Map.keys(payload)) ==
               Enum.sort(
                 ~w(id itemId borrowerPrincipalId status overdue requestedStartOn requestedDueOn
                    approvedStartOn approvedDueOn checkedOutAt returnedAt decidedAt
                    decidedByPrincipalId returnedByPrincipalId requestNote decisionNote
                    itemSlug itemLabel containerPath createdAt)
               )

      assert payload["id"] == loan.id
      assert payload["borrowerPrincipalId"] == loan.borrower_principal_id
      assert payload["status"] == "approved"
      assert payload["itemSlug"] == loan.item_slug
      assert payload["containerPath"] == loan.container_path
      assert payload["overdue"] == false
    end

    test "grants every operator role equal read authority and 401s without a session", %{
      conn: conn
    } do
      %{loan: loan} = approved_loan()

      for role <- @write_roles do
        read =
          build_conn()
          |> auth_conn(role)
          |> get("/api/inventory/operator/loans/#{loan.id}")

        assert json_response(read, 200)["data"]["id"] == loan.id
      end

      anonymous = get(conn, "/api/inventory/operator/loans/#{loan.id}")
      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(anonymous, 401)
    end

    test "refuses members, who must not see borrower or operator facts", %{conn: conn} do
      %{loan: loan} = approved_loan()

      show =
        conn |> auth_conn("member") |> get("/api/inventory/operator/loans/#{loan.id}")

      assert %{"errors" => %{"detail" => "Insufficient role"}} = json_response(show, 403)
    end

    test "404s an unknown loan", %{conn: conn} do
      missing =
        conn
        |> auth_conn("quartermaster")
        |> get("/api/inventory/operator/loans/#{Ecto.UUID.generate()}")

      assert %{"errors" => %{"detail" => "Loan not found"}} = json_response(missing, 404)
    end
  end

  # ── Approve ─────────────────────────────────────────────────────

  describe "approve" do
    test "approves a pending request and notifies the borrower", %{conn: conn} do
      %{item: item} = fixture()
      {:ok, request} = request(item)

      conn =
        conn
        |> auth_conn("quartermaster")
        |> post("/api/inventory/operator/loans/#{request.id}/approve", %{})

      assert %{"data" => payload} = json_response(conn, 200)
      assert payload["status"] == "approved"
      assert payload["containerPath"] != nil

      [row] = Repo.all(Notification)
      assert row.principal_id == payload["borrowerPrincipalId"]
      assert row.notification_key == "inventory:loan:#{request.id}:approved"
      assert row.body =~ payload["itemLabel"]
      assert row.body =~ payload["containerPath"]
    end

    test "answers 409 when the loan is not pending", %{conn: conn} do
      %{loan: loan} = approved_loan()

      conn =
        conn
        |> auth_conn("quartermaster")
        |> post("/api/inventory/operator/loans/#{loan.id}/approve", %{})

      assert %{"errors" => %{"code" => "not_pending"}} = json_response(conn, 409)
    end

    test "answers 422 for inverted dates", %{conn: conn} do
      %{item: item} = fixture()
      {:ok, request} = request(item)
      today = ClubCalendar.today()

      conn =
        conn
        |> auth_conn("quartermaster")
        |> post("/api/inventory/operator/loans/#{request.id}/approve", %{
          "startsOn" => Date.to_iso8601(Date.add(today, 5)),
          "dueOn" => Date.to_iso8601(Date.add(today, 1))
        })

      assert %{"errors" => %{"code" => "invalid_dates"}} = json_response(conn, 422)
    end
  end

  # ── Reject / cancel ─────────────────────────────────────────────

  describe "reject" do
    test "rejects a pending request and notifies the borrower", %{conn: conn} do
      %{item: item} = fixture()
      {:ok, request} = request(item)

      conn =
        conn
        |> auth_conn("president")
        |> post("/api/inventory/operator/loans/#{request.id}/reject", %{
          "note" => "Needed for a workshop"
        })

      assert %{"data" => payload} = json_response(conn, 200)
      assert payload["status"] == "rejected"
      assert payload["decisionNote"] == "Needed for a workshop"

      [row] = Repo.all(Notification)
      assert row.notification_key == "inventory:loan:#{request.id}:rejected"
    end
  end

  describe "cancel" do
    test "cancels an approved loan and notifies the borrower", %{conn: conn} do
      %{loan: loan} = approved_loan()

      conn =
        conn
        |> auth_conn("admin")
        |> post("/api/inventory/operator/loans/#{loan.id}/cancel", %{})

      assert %{"data" => payload} = json_response(conn, 200)
      assert payload["status"] == "cancelled"

      [row] = Repo.all(Notification)
      assert row.notification_key == "inventory:loan:#{loan.id}:cancelled"
    end

    test "answers 409 when the loan is not approved", %{conn: conn} do
      %{item: item} = fixture()
      {:ok, request} = request(item)

      conn =
        conn
        |> auth_conn("quartermaster")
        |> post("/api/inventory/operator/loans/#{request.id}/cancel", %{})

      assert %{"errors" => %{"code" => "not_approved"}} = json_response(conn, 409)
    end
  end

  # ── Checkout / return ───────────────────────────────────────────

  describe "checkout" do
    test "hands over an approved loan and does not notify", %{conn: conn} do
      %{loan: loan} = approved_loan()

      conn =
        conn
        |> auth_conn("quartermaster")
        |> post("/api/inventory/operator/loans/#{loan.id}/checkout", %{})

      assert %{"data" => payload} = json_response(conn, 200)
      assert payload["status"] == "checked_out"
      assert payload["checkedOutAt"] != nil
      assert Repo.all(Notification) == []
    end

    test "answers 409 outside the approved window", %{conn: conn} do
      %{loan: loan} = approved_loan()
      today = ClubCalendar.today()
      set_approved_dates!(loan.id, Date.add(today, 2), Date.add(today, 5))

      conn =
        conn
        |> auth_conn("quartermaster")
        |> post("/api/inventory/operator/loans/#{loan.id}/checkout", %{})

      assert %{"errors" => %{"code" => "outside_window"}} = json_response(conn, 409)
    end
  end

  describe "return" do
    test "returns a checked-out loan and does not notify", %{conn: conn} do
      %{loan: loan} = approved_loan()
      assert {:ok, _} = Inventory.check_out_loan(loan.id, %{}, @actor_id)

      conn =
        conn
        |> auth_conn("quartermaster")
        |> post("/api/inventory/operator/loans/#{loan.id}/return", %{})

      assert %{"data" => payload} = json_response(conn, 200)
      assert payload["status"] == "returned"
      assert payload["returnedAt"] != nil
      assert Repo.all(Notification) == []
    end
  end

  # ── Date edits ──────────────────────────────────────────────────

  describe "editDates" do
    test "edits the due date and notifies the borrower", %{conn: conn} do
      %{loan: loan} = approved_loan()
      new_due = Date.add(loan.approved_due_on, 3)

      conn =
        conn
        |> auth_conn("quartermaster")
        |> post("/api/inventory/operator/loans/#{loan.id}/dates", %{
          "dueOn" => Date.to_iso8601(new_due)
        })

      assert %{"data" => payload} = json_response(conn, 200)
      assert payload["approvedDueOn"] == Date.to_iso8601(new_due)

      [row] = Repo.all(Notification)

      assert row.notification_key ==
               "inventory:loan:#{loan.id}:dates_changed:#{Date.to_gregorian_days(new_due)}"

      assert row.body =~ Date.to_iso8601(new_due)
    end

    test "does not notify when only the start date moves", %{conn: conn} do
      %{loan: loan} = approved_loan()
      new_start = Date.add(loan.approved_start_on, -1)

      conn =
        conn
        |> auth_conn("quartermaster")
        |> post("/api/inventory/operator/loans/#{loan.id}/dates", %{
          "startsOn" => Date.to_iso8601(new_start)
        })

      assert %{"data" => payload} = json_response(conn, 200)
      assert payload["approvedStartOn"] == Date.to_iso8601(new_start)
      assert Repo.all(Notification) == []
    end

    test "answers 409 when the start is moved after checkout", %{conn: conn} do
      %{loan: loan} = approved_loan()
      assert {:ok, _} = Inventory.check_out_loan(loan.id, %{}, @actor_id)

      conn =
        conn
        |> auth_conn("quartermaster")
        |> post("/api/inventory/operator/loans/#{loan.id}/dates", %{
          "startsOn" => Date.to_iso8601(Date.add(ClubCalendar.today(), 1))
        })

      assert %{"errors" => %{"code" => "start_immutable"}} = json_response(conn, 409)
    end
  end

  # ── OpenAPI contract backstops ──────────────────────────────────

  describe "openapi operator loan contract" do
    test "every operator loan operation lives on the one Inventory tag" do
      spec = load_openapi_spec!()

      Enum.each(operator_loan_operations(), fn {path, method, operation_id} ->
        operation = get_in(spec, ["paths", path, method])
        assert operation, "missing #{method} #{path}"
        assert operation["operationId"] == operation_id
        assert operation["tags"] == ["Inventory"]
        assert operation["security"] == [%{"cookieSession" => []}]
        refute operation["description"] =~ "Supabase JWT"
      end)
    end

    test "the viewer schema is distinct from the member loan and names the borrower" do
      spec = load_openapi_spec!()
      operator = get_in(spec, ["components", "schemas", "InventoryOperatorLoan"])
      member = get_in(spec, ["components", "schemas", "InventoryMemberLoan"])

      assert Enum.sort(Map.keys(operator["properties"])) ==
               Enum.sort(
                 ~w(id itemId borrowerPrincipalId status overdue requestedStartOn requestedDueOn
                    approvedStartOn approvedDueOn checkedOutAt returnedAt decidedAt
                    decidedByPrincipalId returnedByPrincipalId requestNote decisionNote
                    itemSlug itemLabel containerPath createdAt)
               )

      refute Map.has_key?(member["properties"], "borrowerPrincipalId")
      refute Map.has_key?(member["properties"], "decidedByPrincipalId")
      refute Map.has_key?(member["properties"], "returnedByPrincipalId")
      refute Map.has_key?(member["properties"], "decidedAt")
    end

    test "each transition has its own request and there is no generic loan patch" do
      spec = load_openapi_spec!()

      refute get_in(spec, ["paths", "/inventory/operator/loans/{loanId}", "patch"])

      assert get_in(spec, [
               "components",
               "schemas",
               "InventoryOperatorLoanApproveRequest",
               "properties"
             ])
             |> Map.keys()
             |> Enum.sort() == ~w(dueOn note startsOn)

      assert get_in(spec, [
               "components",
               "schemas",
               "InventoryOperatorLoanDatesRequest",
               "properties"
             ])
             |> Map.keys()
             |> Enum.sort() == ~w(dueOn startsOn)
    end

    test "interlock conflicts and validation failures are typed" do
      spec = load_openapi_spec!()

      conflict = get_in(spec, ["components", "schemas", "InventoryOperatorLoanConflictError"])
      validation = get_in(spec, ["components", "schemas", "InventoryOperatorLoanValidationError"])

      assert get_in(conflict, ["properties", "errors", "properties", "code", "enum"]) ==
               ~w(not_pending not_approved not_checked_out not_editable item_unavailable
                  already_allocated start_immutable outside_window maintenance_open)

      assert get_in(validation, ["properties", "errors", "properties", "code", "enum"]) ==
               ~w(invalid_dates invalid_note)
    end
  end

  # ── Fixtures ────────────────────────────────────────────────────

  defp approved_loan do
    %{item: item} = fixture()
    {:ok, request} = request(item)
    {:ok, loan} = Inventory.approve_loan(request.id, %{}, @actor_id)
    %{item: item, loan: loan}
  end

  defp fixture do
    {:ok, category} =
      Inventory.create_category(%{
        "name" => "Op loan cat #{System.unique_integer([:positive])}"
      })

    {:ok, root} =
      Inventory.create_container(
        %{"name" => "Clubhouse #{System.unique_integer([:positive])}"},
        @actor_id
      )

    {:ok, shelf} =
      Inventory.create_container(
        %{"name" => "Rack 2", "parent_container_id" => root.id},
        @actor_id
      )

    {:ok, item} =
      Inventory.create_operator_item(
        %{"container_id" => shelf.id, "category_id" => category.id},
        @actor_id
      )

    %{category: category, item: item}
  end

  defp request(item) do
    borrower = principal!()
    today = ClubCalendar.today()

    Inventory.request_loan(
      item.slug,
      %{
        "startsOn" => Date.to_iso8601(today),
        "dueOn" => Date.to_iso8601(Date.add(today, 7))
      },
      borrower
    )
  end

  defp principal! do
    id = Ecto.UUID.generate()

    {:ok, _} =
      Dhc.Auth.register_principal_with_id(id, %{
        email: "borrower-#{System.unique_integer([:positive])}@example.com"
      })

    id
  end

  defp set_approved_dates!(loan_id, starts_on, due_on) do
    Repo.query!(
      "UPDATE inventory_loans SET approved_start_on = $1, approved_due_on = $2 WHERE id = $3",
      [starts_on, due_on, Ecto.UUID.dump!(loan_id)]
    )
  end

  defp operator_loan_operations do
    [
      {"/inventory/operator/loans/{loanId}", "get", "inventoryOperatorLoans.show"},
      {"/inventory/operator/loans/{loanId}/approve", "post", "inventoryOperatorLoans.approve"},
      {"/inventory/operator/loans/{loanId}/reject", "post", "inventoryOperatorLoans.reject"},
      {"/inventory/operator/loans/{loanId}/cancel", "post", "inventoryOperatorLoans.cancel"},
      {"/inventory/operator/loans/{loanId}/checkout", "post", "inventoryOperatorLoans.checkout"},
      {"/inventory/operator/loans/{loanId}/return", "post", "inventoryOperatorLoans.return"},
      {"/inventory/operator/loans/{loanId}/dates", "post", "inventoryOperatorLoans.editDates"}
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
