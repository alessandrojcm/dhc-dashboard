defmodule DhcWeb.InventoryMemberLoansControllerTest do
  @moduledoc """
  Request/contract tests for the ALE-285 own-loan viewers and cancel command.

  The own-loan boundary is the centre of this suite: every action scopes to
  the caller, another member's loan answers `404` rather than `403`, and the
  rendered loan carries no borrower or deciding-operator field. Alongside
  that: the complete history including rejections and cancellations, the
  status filter, the container path appearing only from approval onward,
  derived overdue, and the typed conflict for a loan past checkout.

  Domain invariants live in `Dhc.Inventory.MemberLoansTest`. Operator
  transitions are ALE-286 and appear here as SQL fixtures.
  """

  use DhcWeb.ConnCase, async: false

  alias Dhc.Inventory
  alias Dhc.Inventory.ClubCalendar
  alias Dhc.Repo

  @actor_id "44444444-4444-4444-4444-444444444444"

  defmodule Verifier do
    @actor_id "44444444-4444-4444-4444-444444444444"

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

    {:ok, _} = Dhc.Auth.register_principal_with_id(@actor_id, %{email: "loans@example.com"})

    on_exit(fn -> Application.put_env(:dhc, :auth_verifier, original) end)

    :ok
  end

  defp auth_conn(conn, role), do: put_req_header(conn, "authorization", "Bearer #{role}-token")

  # ── Own-loan boundary ───────────────────────────────────────────

  describe "own-loan boundary" do
    test "lists only the caller's loans", %{conn: conn} do
      %{item: item} = fixture()
      stranger = principal!("stranger")

      mine = create_loan!(item, @actor_id, "requested")
      theirs = create_loan!(create_item!(), stranger, "checked_out")

      conn = conn |> auth_conn("member") |> get("/api/inventory/loans/mine")

      assert %{"data" => %{"loans" => loans}} = json_response(conn, 200)
      assert Enum.map(loans, & &1["id"]) == [mine]

      body = Jason.encode!(loans)
      refute body =~ theirs
      refute body =~ stranger
    end

    test "another member's loan is 404, never 403", %{conn: conn} do
      stranger = principal!("stranger")
      theirs = create_loan!(create_item!(), stranger, "approved")

      show = conn |> auth_conn("member") |> get("/api/inventory/loans/mine/#{theirs}")
      assert %{"errors" => %{"detail" => "Loan not found"}} = json_response(show, 404)

      cancel =
        build_conn()
        |> auth_conn("member")
        |> post("/api/inventory/loans/mine/#{theirs}/cancel", %{})

      assert %{"errors" => %{"detail" => "Loan not found"}} = json_response(cancel, 404)

      # An operator role gets no extra reach through these routes either;
      # the operator queue is a separate slice (ALE-286).
      as_operator =
        build_conn() |> auth_conn("quartermaster") |> get("/api/inventory/loans/mine/#{theirs}")

      assert %{"errors" => %{"detail" => "Loan not found"}} = json_response(as_operator, 404)
    end

    test "requires a session", %{conn: conn} do
      %{item: item} = fixture()
      loan_id = create_loan!(item, @actor_id, "requested")

      assert %{"errors" => %{"detail" => "Unauthorized"}} =
               conn |> get("/api/inventory/loans/mine") |> json_response(401)

      assert %{"errors" => %{"detail" => "Unauthorized"}} =
               build_conn()
               |> get("/api/inventory/loans/mine/#{loan_id}")
               |> json_response(401)

      assert %{"errors" => %{"detail" => "Unauthorized"}} =
               build_conn()
               |> post("/api/inventory/loans/mine/#{loan_id}/cancel", %{})
               |> json_response(401)
    end
  end

  # ── Payload ─────────────────────────────────────────────────────

  describe "loan payload" do
    test "carries the member fields and no borrower or deciding operator", %{conn: conn} do
      %{item: item} = fixture()
      loan_id = create_loan!(item, @actor_id, "requested")

      conn = conn |> auth_conn("member") |> get("/api/inventory/loans/mine/#{loan_id}")

      assert %{"data" => loan} = json_response(conn, 200)

      assert Enum.sort(Map.keys(loan)) ==
               Enum.sort(
                 ~w(id itemId status overdue requestedStartOn requestedDueOn approvedStartOn
                    approvedDueOn checkedOutAt returnedAt requestNote decisionNote itemSlug
                    itemLabel containerPath createdAt)
               )

      assert loan["itemSlug"] == item.slug
      assert is_binary(loan["itemLabel"])
    end

    test "keeps the item snapshot after the item is archived", %{conn: conn} do
      %{item: item} = fixture()
      loan_id = create_loan!(item, @actor_id, "returned")

      assert {:ok, _} = Inventory.archive_operator_item(item.slug, %{}, @actor_id)

      conn = conn |> auth_conn("member") |> get("/api/inventory/loans/mine/#{loan_id}")

      assert %{"data" => loan} = json_response(conn, 200)
      assert loan["itemSlug"] == item.slug
      assert is_binary(loan["itemLabel"])
    end

    test "discloses the container path only from approval onward", %{conn: conn} do
      %{item: item} = fixture()
      loan_id = create_loan!(item, @actor_id, "requested")
      set_container_path!(loan_id, "Clubhouse › Rack 2")

      pending = conn |> auth_conn("member") |> get("/api/inventory/loans/mine/#{loan_id}")
      assert json_response(pending, 200)["data"]["containerPath"] == nil

      set_status!(loan_id, "approved")

      approved =
        build_conn() |> auth_conn("member") |> get("/api/inventory/loans/mine/#{loan_id}")

      assert json_response(approved, 200)["data"]["containerPath"] == "Clubhouse › Rack 2"
    end

    test "renders overdue as derived, not stored", %{conn: conn} do
      %{item: item} = fixture()
      today = ClubCalendar.today()
      loan_id = create_loan!(item, @actor_id, "checked_out")
      set_approved_dates!(loan_id, Date.add(today, -10), Date.add(today, -1))

      late = conn |> auth_conn("member") |> get("/api/inventory/loans/mine/#{loan_id}")
      assert json_response(late, 200)["data"]["overdue"] == true
      assert json_response(late, 200)["data"]["status"] == "checked_out"

      set_approved_dates!(loan_id, Date.add(today, -10), Date.add(today, 3))

      extended =
        build_conn() |> auth_conn("member") |> get("/api/inventory/loans/mine/#{loan_id}")

      assert json_response(extended, 200)["data"]["overdue"] == false
    end
  end

  # ── History ─────────────────────────────────────────────────────

  describe "history" do
    test "includes rejections and cancellations with their notes", %{conn: conn} do
      %{item: item} = fixture()

      rejected = create_loan!(item, @actor_id, "rejected")

      reject!(rejected, "Rejected automatically: the item went into maintenance.")

      cancelled = create_loan!(create_item!(), @actor_id, "cancelled")

      conn = conn |> auth_conn("member") |> get("/api/inventory/loans/mine")

      assert %{"data" => %{"loans" => loans}} = json_response(conn, 200)
      assert Enum.sort(Enum.map(loans, & &1["id"])) == Enum.sort([rejected, cancelled])

      rejected_view = Enum.find(loans, &(&1["id"] == rejected))

      assert rejected_view["decisionNote"] ==
               "Rejected automatically: the item went into maintenance."
    end

    test "filters to open or closed and rejects an unknown filter", %{conn: conn} do
      %{item: item} = fixture()
      open = create_loan!(item, @actor_id, "approved")
      closed = create_loan!(create_item!(), @actor_id, "returned")

      open_page =
        conn
        |> auth_conn("member")
        |> get("/api/inventory/loans/mine", %{"status" => "open"})

      assert %{"data" => %{"loans" => open_loans}} = json_response(open_page, 200)
      assert Enum.map(open_loans, & &1["id"]) == [open]

      closed_page =
        build_conn()
        |> auth_conn("member")
        |> get("/api/inventory/loans/mine", %{"status" => "closed"})

      assert %{"data" => %{"loans" => closed_loans}} = json_response(closed_page, 200)
      assert Enum.map(closed_loans, & &1["id"]) == [closed]

      bad =
        build_conn()
        |> auth_conn("member")
        |> get("/api/inventory/loans/mine", %{"status" => "pending"})

      assert %{"errors" => %{"detail" => detail}} = json_response(bad, 400)
      assert detail =~ "status"
    end

    test "pages with exact totalCount and cursor metadata", %{conn: conn} do
      loan_ids = for _ <- 1..12, do: create_loan!(create_item!(), @actor_id, "returned")

      first =
        conn |> auth_conn("member") |> get("/api/inventory/loans/mine", %{"limit" => "10"})

      assert %{"data" => data} = json_response(first, 200)
      assert data["totalCount"] == 12
      assert data["limit"] == 10
      assert data["previousCursor"] == nil
      assert is_binary(data["nextCursor"])

      second =
        build_conn()
        |> auth_conn("member")
        |> get("/api/inventory/loans/mine", %{
          "limit" => "10",
          "cursor" => data["nextCursor"]
        })

      assert %{"data" => page_two} = json_response(second, 200)
      assert page_two["totalCount"] == 12
      assert page_two["nextCursor"] == nil

      paged = Enum.map(data["loans"] ++ page_two["loans"], & &1["id"])
      assert Enum.sort(paged) == Enum.sort(loan_ids)
    end

    test "answers 400 for a bad limit or mismatched cursor", %{conn: conn} do
      for _ <- 1..12, do: create_loan!(create_item!(), @actor_id, "returned")

      bad_limit =
        conn |> auth_conn("member") |> get("/api/inventory/loans/mine", %{"limit" => "7"})

      assert %{"errors" => %{"detail" => limit_detail}} = json_response(bad_limit, 400)
      assert limit_detail =~ "limit"

      page =
        build_conn()
        |> auth_conn("member")
        |> get("/api/inventory/loans/mine", %{"limit" => "10"})

      cursor = json_response(page, 200)["data"]["nextCursor"]

      stale =
        build_conn()
        |> auth_conn("member")
        |> get("/api/inventory/loans/mine", %{
          "limit" => "10",
          "cursor" => cursor,
          "status" => "open"
        })

      assert %{"errors" => %{"detail" => cursor_detail}} = json_response(stale, 400)
      assert cursor_detail =~ "cursor"
    end
  end

  # ── Cancel ──────────────────────────────────────────────────────

  describe "cancel" do
    test "cancels an own pre-checkout loan and is idempotent", %{conn: conn} do
      %{item: item} = fixture()
      loan_id = create_loan!(item, @actor_id, "requested")

      conn =
        conn
        |> auth_conn("member")
        |> post("/api/inventory/loans/mine/#{loan_id}/cancel", %{"note" => "Plans changed"})

      assert %{"data" => loan} = json_response(conn, 200)
      assert loan["status"] == "cancelled"
      assert loan["decisionNote"] == "Plans changed"

      again =
        build_conn()
        |> auth_conn("member")
        |> post("/api/inventory/loans/mine/#{loan_id}/cancel", %{})

      assert json_response(again, 200)["data"]["status"] == "cancelled"
    end

    test "answers 409 once the loan is checked out or closed", %{conn: conn} do
      %{item: item} = fixture()
      checked_out = create_loan!(item, @actor_id, "checked_out")

      conn =
        conn
        |> auth_conn("member")
        |> post("/api/inventory/loans/mine/#{checked_out}/cancel", %{})

      assert %{"errors" => errors} = json_response(conn, 409)
      assert errors["code"] == "not_cancellable"

      returned = create_loan!(create_item!(), @actor_id, "returned")

      closed =
        build_conn()
        |> auth_conn("member")
        |> post("/api/inventory/loans/mine/#{returned}/cancel", %{})

      assert %{"errors" => %{"code" => "not_cancellable"}} = json_response(closed, 409)
    end
  end

  # ── Fixtures ────────────────────────────────────────────────────

  defp fixture do
    %{item: create_item!()}
  end

  defp create_item! do
    {:ok, item} =
      Inventory.create_operator_item(
        %{
          "container_id" => create_container!().id,
          "category_id" => create_category!().id
        },
        @actor_id
      )

    item
  end

  defp create_category! do
    {:ok, category} =
      Inventory.create_category(%{
        "name" => "Loan HTTP category #{System.unique_integer([:positive])}"
      })

    category
  end

  defp create_container! do
    {:ok, container} =
      Inventory.create_container(
        %{"name" => "Loan HTTP container #{System.unique_integer([:positive])}"},
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

  # ── Operator-side fixtures (ALE-286 owns these commands) ────────

  defp create_loan!(item, borrower_id, status) do
    %{rows: [[loan_id]]} =
      Repo.query!(
        """
        INSERT INTO inventory_loans (
          item_id, borrower_principal_id, status,
          requested_start_on, requested_due_on,
          approved_start_on, approved_due_on,
          item_slug_snapshot, item_label_snapshot,
          created_at, updated_at
        )
        VALUES ($1, $2, $3, CURRENT_DATE, CURRENT_DATE + 7,
                CURRENT_DATE, CURRENT_DATE + 7, $4, $5, NOW(), NOW())
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

  defp set_status!(loan_id, status) do
    Repo.query!("UPDATE inventory_loans SET status = $1 WHERE id = $2", [
      status,
      Ecto.UUID.dump!(loan_id)
    ])
  end

  defp reject!(loan_id, note) do
    Repo.query!(
      "UPDATE inventory_loans SET status = 'rejected', decided_at = NOW(), decision_note = $1 WHERE id = $2",
      [note, Ecto.UUID.dump!(loan_id)]
    )
  end

  defp set_container_path!(loan_id, path) do
    Repo.query!(
      "UPDATE inventory_loans SET approved_container_path_snapshot = $1 WHERE id = $2",
      [path, Ecto.UUID.dump!(loan_id)]
    )
  end

  defp set_approved_dates!(loan_id, starts_on, due_on) do
    Repo.query!(
      "UPDATE inventory_loans SET approved_start_on = $1, approved_due_on = $2 WHERE id = $3",
      [starts_on, due_on, Ecto.UUID.dump!(loan_id)]
    )
  end
end
