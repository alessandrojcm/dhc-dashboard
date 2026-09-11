defmodule Dhc.Inventory.OperatorLoansTest do
  @moduledoc """
  ALE-296 (ALE-286a): the operator half of the loan lifecycle.

  Proves through `Dhc.Inventory` that the ALE-273 transitions are exactly
  `requested → approved/rejected`, `approved → checked_out/cancelled`, and
  `checked_out → returned`; that approval reserves the item exactly once and
  atomically rejects every competing request; that checkout is gated to the
  approved window and an out-of-maintenance item; that the start date is
  immutable after checkout while the due date stays editable; and that
  overdue is only ever derived.

  Requests are created through the real member command
  (`Dhc.Inventory.request_loan/3`), so the two halves of the lifecycle are
  proven to compose rather than being stitched together by SQL fixtures.
  Direct SQL appears only to prove the backstop the seam cannot express (the
  partial unique index `inventory_loans_one_active_allocation_per_item`) and
  to age a loan past its due date, which no command may do.

  Concurrency note: the races run on real independent connections through
  `Ecto.Adapters.SQL.Sandbox.unboxed_run/2`, so Postgres settles them rather
  than test-process ordering. That commits outside the test-owner
  transaction, so each race builds its fixture and deletes its rows
  explicitly (docs/agents/critical-patterns.md, "Real PostgreSQL Concurrency
  Tests"). Each asserts what must hold under *any* interleaving: exactly one
  winner, and the loser gets a domain conflict rather than a server error.

  Notifications are deliberately absent — ALE-287 owns the keyed seam and is
  a hard prerequisite before these commands are exposed (ALE-296 scope note).
  """

  use Dhc.DataCase, async: false

  alias Dhc.Auth.Principal
  alias Dhc.Inventory
  alias Dhc.Inventory.ClubCalendar
  alias Dhc.Repo
  alias Ecto.Adapters.SQL.Sandbox

  describe "approve" do
    test "reserves the item and carries the requested dates forward" do
      %{item: item} = fixture()
      member = principal_id()
      today = ClubCalendar.today()
      due = Date.add(today, 7)

      {:ok, request} = request(item, member, today, due)
      operator = principal_id()

      assert {:ok, approved} = Inventory.approve_loan(request.id, %{}, operator)
      assert approved.status == "approved"
      assert approved.approved_start_on == today
      assert approved.approved_due_on == due
      assert approved.decided_by_principal_id == operator
      assert approved.decided_at != nil

      # Approval is what reserves the item: it is no longer available.
      assert {:ok, resolved} = Inventory.resolve_operator_item(item.slug)
      assert resolved.availability == %{available?: false, status: :on_loan}
    end

    test "may adjust the dates at approval time" do
      %{item: item} = fixture()
      today = ClubCalendar.today()

      {:ok, request} = request(item, principal_id(), today, Date.add(today, 3))
      shifted_start = Date.add(today, 1)
      shifted_due = Date.add(today, 10)

      assert {:ok, approved} =
               Inventory.approve_loan(
                 request.id,
                 %{
                   "startsOn" => Date.to_iso8601(shifted_start),
                   "dueOn" => Date.to_iso8601(shifted_due)
                 },
                 principal_id()
               )

      assert approved.approved_start_on == shifted_start
      assert approved.approved_due_on == shifted_due
      # The requested dates are a retained fact and are never rewritten.
      assert approved.requested_start_on == today
      assert approved.requested_due_on == Date.add(today, 3)
    end

    test "accepts a past start date, unlike a member request" do
      %{item: item} = fixture()
      today = ClubCalendar.today()

      {:ok, request} = request(item, principal_id(), today, Date.add(today, 3))

      # A request may not start in the past, but by approval time the
      # requested start can legitimately have passed, and the operator may
      # still record what actually happened (story 36/37).
      assert {:ok, approved} =
               Inventory.approve_loan(
                 request.id,
                 %{"startsOn" => Date.to_iso8601(Date.add(today, -2))},
                 principal_id()
               )

      assert approved.approved_start_on == Date.add(today, -2)
    end

    test "refuses an inverted date range" do
      %{item: item} = fixture()
      today = ClubCalendar.today()
      {:ok, request} = request(item, principal_id(), today, Date.add(today, 3))

      assert {:error, :invalid_dates} =
               Inventory.approve_loan(
                 request.id,
                 %{
                   "startsOn" => Date.to_iso8601(Date.add(today, 5)),
                   "dueOn" => Date.to_iso8601(Date.add(today, 1))
                 },
                 principal_id()
               )

      assert {:error, :invalid_dates} =
               Inventory.approve_loan(request.id, %{"dueOn" => "not-a-date"}, principal_id())
    end

    test "rejects every competing request with a system note" do
      %{item: item} = fixture()
      winner = principal_id()
      first_loser = principal_id()
      second_loser = principal_id()

      {:ok, winning} = request(item, winner)
      {:ok, first} = request(item, first_loser)
      {:ok, second} = request(item, second_loser)

      assert {:ok, _approved} = Inventory.approve_loan(winning.id, %{}, principal_id())

      # Allocation is exactly-once: the competitors are closed in the same
      # transaction, not left pending for a second decision (story 35).
      for {loan, borrower} <- [{first, first_loser}, {second, second_loser}] do
        assert {:ok, rejected} = Inventory.get_own_loan(loan.id, borrower)
        assert rejected.status == "rejected"
        assert rejected.decision_note =~ "another request"
      end

      assert pending_count(item) == 0
      assert active_allocation_count(item) == 1
    end

    test "refuses a loan that is not pending" do
      %{item: item} = fixture()
      {:ok, request} = request(item, principal_id())
      assert {:ok, _} = Inventory.approve_loan(request.id, %{}, principal_id())

      # Approval has allocation side effects, so a repeated call is an
      # error rather than a silent no-op: the caller must be able to tell
      # whether *this* call reserved the item.
      assert {:error, :not_pending} = Inventory.approve_loan(request.id, %{}, principal_id())
    end

    test "refuses when another loan already holds the item" do
      %{item: item} = fixture()
      {:ok, holder} = request(item, principal_id())
      {:ok, contender} = request(item, principal_id())

      assert {:ok, _} = Inventory.approve_loan(holder.id, %{}, principal_id())
      # The competing request was rejected by that approval, so re-request
      # to get a pending row against a held item.
      assert {:error, :item_unavailable} = request(item, principal_id())
      assert {:error, :not_pending} = Inventory.approve_loan(contender.id, %{}, principal_id())
    end

    test "refuses an item in maintenance or archived" do
      %{item: item} = fixture()
      {:ok, request} = request(item, principal_id())

      assert {:ok, _} =
               Inventory.start_operator_item_maintenance(
                 item.slug,
                 %{"reason" => "Blade bent"},
                 principal_id()
               )

      # Maintenance rejected the pending request (ALE-294), so the loan is
      # no longer pending — which is itself the refusal.
      assert {:error, :not_pending} = Inventory.approve_loan(request.id, %{}, principal_id())

      other = create_item!()
      {:ok, second} = request(other, principal_id())
      assert {:ok, _} = Inventory.archive_operator_item(other.slug, %{}, principal_id())
      assert {:error, :not_pending} = Inventory.approve_loan(second.id, %{}, principal_id())
    end

    test "snapshots the container path for the borrower's collection flow" do
      root = create_container!()

      {:ok, shelf} =
        Inventory.create_container(
          %{"name" => "Rack 2", "parent_container_id" => root.id},
          principal_id()
        )

      category = create_category!()
      {:ok, item} = create_operator_item(shelf.id, category.id)
      member = principal_id()
      {:ok, request} = request(item, member)

      # Before approval the location is not disclosed to the member.
      assert {:ok, pending} = Inventory.get_own_loan(request.id, member)
      assert pending.container_path == nil

      assert {:ok, approved} = Inventory.approve_loan(request.id, %{}, principal_id())
      assert approved.container_path == "#{root.name} › Rack 2"

      # And now it is, on the member's own loan only (story 15).
      assert {:ok, visible} = Inventory.get_own_loan(request.id, member)
      assert visible.container_path == "#{root.name} › Rack 2"
    end
  end

  describe "reject" do
    test "closes a pending request with an operator note" do
      %{item: item} = fixture()
      member = principal_id()
      {:ok, request} = request(item, member)
      operator = principal_id()

      assert {:ok, rejected} =
               Inventory.reject_loan(request.id, %{"note" => "  Needed for a course  "}, operator)

      assert rejected.status == "rejected"
      assert rejected.decision_note == "Needed for a course"
      assert rejected.decided_by_principal_id == operator

      # Rejection reserves nothing, so the item stays available.
      assert {:ok, resolved} = Inventory.resolve_operator_item(item.slug)
      assert resolved.availability.available? == true
    end

    test "refuses anything that is not pending" do
      %{item: item} = fixture()
      {:ok, request} = request(item, principal_id())
      assert {:ok, _} = Inventory.approve_loan(request.id, %{}, principal_id())

      assert {:error, :not_pending} = Inventory.reject_loan(request.id, %{}, principal_id())

      assert {:error, :not_found} =
               Inventory.reject_loan(Ecto.UUID.generate(), %{}, principal_id())

      assert {:error, :not_found} = Inventory.reject_loan("not-a-uuid", %{}, principal_id())
    end
  end

  describe "operator cancel" do
    test "cancels an approved loan and releases the item" do
      %{item: item} = fixture()
      {:ok, request} = request(item, principal_id())
      assert {:ok, _} = Inventory.approve_loan(request.id, %{}, principal_id())
      operator = principal_id()

      assert {:ok, cancelled} =
               Inventory.cancel_operator_loan(request.id, %{"note" => "Item needed"}, operator)

      assert cancelled.status == "cancelled"
      assert cancelled.decision_note == "Item needed"
      assert cancelled.decided_by_principal_id == operator

      assert active_allocation_count(item) == 0
      assert {:ok, _fresh} = request(item, principal_id())
    end

    test "does not duplicate the member's request cancellation or the return" do
      %{item: item} = fixture()
      {:ok, pending} = request(item, principal_id())

      # A pending request is rejected, never operator-cancelled.
      assert {:error, :not_approved} =
               Inventory.cancel_operator_loan(pending.id, %{}, principal_id())

      assert {:ok, _} = Inventory.approve_loan(pending.id, %{}, principal_id())
      assert {:ok, _} = check_out(pending.id)

      # After checkout the member holds the item, so release is a return.
      assert {:error, :not_approved} =
               Inventory.cancel_operator_loan(pending.id, %{}, principal_id())
    end
  end

  describe "checkout" do
    test "hands over an approved loan inside its window" do
      %{item: item} = fixture()
      {:ok, request} = request(item, principal_id())
      assert {:ok, _} = Inventory.approve_loan(request.id, %{}, principal_id())
      operator = principal_id()

      assert {:ok, out} = Inventory.check_out_loan(request.id, %{}, operator)
      assert out.status == "checked_out"
      assert out.checked_out_at != nil
      assert out.overdue? == false

      # The item stays held, now by custody rather than a reservation.
      assert {:ok, resolved} = Inventory.resolve_operator_item(item.slug)
      assert resolved.availability == %{available?: false, status: :on_loan}
    end

    test "refuses before the start date and after the due date" do
      %{item: item} = fixture()
      today = ClubCalendar.today()
      {:ok, request} = request(item, principal_id(), today, Date.add(today, 3))

      assert {:ok, _} =
               Inventory.approve_loan(
                 request.id,
                 %{"startsOn" => Date.to_iso8601(Date.add(today, 2))},
                 principal_id()
               )

      assert {:error, :outside_window} = check_out(request.id)

      # The operator fixes the dates first, then hands over (story 37).
      assert {:ok, _} =
               Inventory.edit_loan_dates(
                 request.id,
                 %{"startsOn" => Date.to_iso8601(today)},
                 principal_id()
               )

      assert {:ok, out} = check_out(request.id)
      assert out.status == "checked_out"

      late = create_item!()
      {:ok, late_request} = request(late, principal_id(), today, Date.add(today, 1))
      assert {:ok, _} = Inventory.approve_loan(late_request.id, %{}, principal_id())
      set_approved_dates!(late_request.id, Date.add(today, -5), Date.add(today, -2))

      assert {:error, :outside_window} = check_out(late_request.id)
    end

    test "refuses a loan that is not approved" do
      %{item: item} = fixture()
      {:ok, request} = request(item, principal_id())

      assert {:error, :not_approved} = check_out(request.id)

      assert {:ok, _} = Inventory.approve_loan(request.id, %{}, principal_id())
      assert {:ok, _} = check_out(request.id)
      assert {:error, :not_approved} = check_out(request.id)
    end
  end

  describe "return" do
    test "releases the item immediately with no condition outcome" do
      %{item: item} = fixture()
      {:ok, request} = request(item, principal_id())
      assert {:ok, _} = Inventory.approve_loan(request.id, %{}, principal_id())
      assert {:ok, out} = check_out(request.id)
      operator = principal_id()

      assert {:ok, returned} = Inventory.return_loan(request.id, operator)
      assert returned.status == "returned"
      assert returned.returned_at != nil
      assert returned.returned_by_principal_id == operator
      # Actual handover timestamps are kept separate from the approved dates.
      assert returned.checked_out_at == out.checked_out_at
      assert returned.approved_due_on != nil

      assert {:ok, resolved} = Inventory.resolve_operator_item(item.slug)
      assert resolved.availability == %{available?: true, status: :available}
      assert {:ok, _} = request(item, principal_id())
    end

    test "refuses a loan that is not checked out" do
      %{item: item} = fixture()
      {:ok, request} = request(item, principal_id())

      assert {:error, :not_checked_out} = Inventory.return_loan(request.id, principal_id())
      assert {:ok, _} = Inventory.approve_loan(request.id, %{}, principal_id())
      assert {:error, :not_checked_out} = Inventory.return_loan(request.id, principal_id())
    end
  end

  describe "date edits and derived overdue" do
    test "keeps the start editable before checkout and immutable after" do
      %{item: item} = fixture()
      today = ClubCalendar.today()
      {:ok, request} = request(item, principal_id(), today, Date.add(today, 3))
      assert {:ok, _} = Inventory.approve_loan(request.id, %{}, principal_id())

      moved = Date.add(today, 1)

      assert {:ok, edited} =
               Inventory.edit_loan_dates(
                 request.id,
                 %{"startsOn" => Date.to_iso8601(moved)},
                 principal_id()
               )

      assert edited.approved_start_on == moved

      set_approved_dates!(request.id, today, Date.add(today, 3))
      assert {:ok, _} = check_out(request.id)

      assert {:error, :start_immutable} =
               Inventory.edit_loan_dates(
                 request.id,
                 %{"startsOn" => Date.to_iso8601(Date.add(today, 2))},
                 principal_id()
               )

      # The due date stays editable after checkout (ALE-279 supersedes the
      # earlier no-edits rule).
      extended = Date.add(today, 30)

      assert {:ok, pushed} =
               Inventory.edit_loan_dates(
                 request.id,
                 %{"dueOn" => Date.to_iso8601(extended)},
                 principal_id()
               )

      assert pushed.approved_due_on == extended
    end

    test "refuses a due date before the actual handover" do
      %{item: item} = fixture()
      today = ClubCalendar.today()
      {:ok, request} = request(item, principal_id(), today, Date.add(today, 7))
      assert {:ok, _} = Inventory.approve_loan(request.id, %{}, principal_id())
      assert {:ok, _} = check_out(request.id)

      # The approved start may legitimately predate the handover, so
      # `dueOn >= startsOn` is not enough: the due date may not precede the
      # moment the member actually took the item (ALE-273).
      set_approved_dates!(request.id, Date.add(today, -5), Date.add(today, 7))

      assert {:error, :invalid_dates} =
               Inventory.edit_loan_dates(
                 request.id,
                 %{"dueOn" => Date.to_iso8601(Date.add(today, -2))},
                 principal_id()
               )

      # The handover day itself is legal — a same-day return is a real loan.
      assert {:ok, same_day} =
               Inventory.edit_loan_dates(
                 request.id,
                 %{"dueOn" => Date.to_iso8601(today)},
                 principal_id()
               )

      assert same_day.approved_due_on == today
    end

    test "refuses an inverted range and a closed loan" do
      %{item: item} = fixture()
      today = ClubCalendar.today()
      {:ok, request} = request(item, principal_id(), today, Date.add(today, 3))
      assert {:ok, _} = Inventory.approve_loan(request.id, %{}, principal_id())

      assert {:error, :invalid_dates} =
               Inventory.edit_loan_dates(
                 request.id,
                 %{"dueOn" => Date.to_iso8601(Date.add(today, -1))},
                 principal_id()
               )

      assert {:ok, _} = Inventory.cancel_operator_loan(request.id, %{}, principal_id())

      assert {:error, :not_editable} =
               Inventory.edit_loan_dates(
                 request.id,
                 %{"dueOn" => Date.to_iso8601(Date.add(today, 5))},
                 principal_id()
               )
    end

    test "derives overdue from the approved due date and undoes it on an extension" do
      %{item: item} = fixture()
      today = ClubCalendar.today()
      {:ok, request} = request(item, principal_id(), today, Date.add(today, 1))
      assert {:ok, _} = Inventory.approve_loan(request.id, %{}, principal_id())
      assert {:ok, out} = check_out(request.id)
      assert out.overdue? == false

      # Ageing the row is the one thing no command may do, so it is SQL.
      set_approved_dates!(request.id, Date.add(today, -10), Date.add(today, -1))

      assert {:ok, late} = Inventory.get_operator_loan(request.id)
      assert late.overdue? == true

      # Overdue is derived, never stored: pushing the due date out makes the
      # loan on time again with no transition to undo (story 41).
      assert {:ok, pushed} =
               Inventory.edit_loan_dates(
                 request.id,
                 %{"dueOn" => Date.to_iso8601(Date.add(today, 5))},
                 principal_id()
               )

      assert pushed.overdue? == false
      assert pushed.status == "checked_out"

      # A closed loan is never overdue, however late it was.
      set_approved_dates!(request.id, Date.add(today, -10), Date.add(today, -1))
      assert {:ok, returned} = Inventory.return_loan(request.id, principal_id())
      assert returned.overdue? == false
    end
  end

  describe "operator read" do
    test "discloses the borrower and the container path" do
      %{item: item} = fixture()
      member = principal_id()
      {:ok, request} = request(item, member)

      assert {:ok, view} = Inventory.get_operator_loan(request.id)
      assert view.borrower_principal_id == member
      assert view.item_slug == item.slug
      assert view.status == "requested"

      assert {:error, :not_found} = Inventory.get_operator_loan(Ecto.UUID.generate())
      assert {:error, :not_found} = Inventory.get_operator_loan("not-a-uuid")
    end
  end

  describe "concurrency" do
    test "two approvals of competing requests reserve the item exactly once" do
      committed(fn %{item: item} ->
        {:ok, first} = request(item, principal_id())
        {:ok, second} = request(item, principal_id())

        results =
          race([
            fn -> Inventory.approve_loan(first.id, %{}, principal_id()) end,
            fn -> Inventory.approve_loan(second.id, %{}, principal_id()) end
          ])

        # Exactly one approval allocates; the loser sees a domain conflict,
        # never a Postgrex error from the active-allocation index.
        assert Enum.count(results, &match?({:ok, _}, &1)) == 1

        assert Enum.count(results, fn
                 {:error, reason} -> reason in [:already_allocated, :not_pending]
                 _other -> false
               end) == 1

        assert active_allocation_count(item) == 1
      end)
    end

    test "an approval racing a maintenance start leaves the item in one state" do
      committed(fn %{item: item} ->
        {:ok, request} = request(item, principal_id())

        [approval, maintenance] =
          race([
            fn -> Inventory.approve_loan(request.id, %{}, principal_id()) end,
            fn ->
              Inventory.start_operator_item_maintenance(
                item.id,
                %{"reason" => "Servicing"},
                principal_id()
              )
            end
          ])

        # Both orders are legal, but they cannot both take the item: either
        # maintenance blocks on the reservation, or the approval finds the
        # request already rejected by maintenance.
        case {approval, maintenance} do
          {{:ok, _}, {:error, :loan_active}} ->
            assert active_allocation_count(item) == 1

          {{:error, reason}, {:ok, _}} ->
            assert reason in [:not_pending, :maintenance_open]
            assert active_allocation_count(item) == 0
        end
      end)
    end

    test "an approval racing the member's cancellation settles without deadlock" do
      committed(fn %{item: item} ->
        member = principal_id()
        {:ok, request} = request(item, member)

        # Both commands lock the item before the loan, so they queue rather
        # than deadlock (docs/agents/critical-patterns.md, lock order).
        [approval, cancellation] =
          race([
            fn -> Inventory.approve_loan(request.id, %{}, principal_id()) end,
            fn -> Inventory.cancel_loan(request.id, %{}, member) end
          ])

        assert match?({:ok, _}, approval) or match?({:error, :not_pending}, approval)
        assert match?({:ok, _}, cancellation) or match?({:error, :not_cancellable}, cancellation)

        # Whoever won, the loan may not be both cancelled and holding the item.
        assert {:ok, final} = Inventory.get_operator_loan(request.id)
        assert final.status in ~w(approved cancelled)

        expected = if final.status == "approved", do: 1, else: 0
        assert active_allocation_count(item) == expected
      end)
    end

    test "two checkouts of one approved loan hand it over once" do
      committed(fn %{item: item} ->
        {:ok, request} = request(item, principal_id())
        {:ok, _} = Inventory.approve_loan(request.id, %{}, principal_id())

        results = race([fn -> check_out(request.id) end, fn -> check_out(request.id) end])

        assert Enum.count(results, &match?({:ok, _}, &1)) == 1
        assert Enum.count(results, &match?({:error, :not_approved}, &1)) == 1
      end)
    end
  end

  # ── Backstop ────────────────────────────────────────────────────

  describe "database backstops" do
    test "the active-allocation index refuses a second live claim written outside the seam" do
      %{item: item} = fixture()
      {:ok, request} = request(item, principal_id())
      assert {:ok, _} = Inventory.approve_loan(request.id, %{}, principal_id())

      # Proves the seam is not the only thing keeping allocation
      # exactly-once: a writer bypassing it still fails at the database.
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          """
          INSERT INTO inventory_loans (
            item_id, borrower_principal_id, status,
            requested_start_on, requested_due_on,
            approved_start_on, approved_due_on,
            item_slug_snapshot, item_label_snapshot, created_at, updated_at
          )
          VALUES ($1, $2, 'approved', CURRENT_DATE, CURRENT_DATE + 7,
                  CURRENT_DATE, CURRENT_DATE + 7, $3, $3, NOW(), NOW())
          """,
          [Ecto.UUID.dump!(item.id), Ecto.UUID.dump!(principal_id()), item.slug]
        )
      end
    end
  end

  # ── Real-concurrency helpers ───────────────────────────────────

  # Builds the fixture outside the sandbox so competing connections can see
  # it, runs `fun`, then removes every committed row it created. Sandbox
  # rollback cannot undo `unboxed_run` work.
  defp committed(fun) do
    context =
      outside_sandbox(fn ->
        category = create_category!()
        container = create_container!()
        {:ok, item} = create_operator_item(container.id, category.id)

        %{category: category, container_id: container.id, item: item}
      end)

    on_exit(fn -> outside_sandbox(fn -> cleanup_committed(context) end) end)

    outside_sandbox(fn -> fun.(context) end)
  end

  defp cleanup_committed(context) do
    item_id = Ecto.UUID.dump!(context.item.id)

    Repo.query!("DELETE FROM inventory_loans WHERE item_id = $1", [item_id])
    Repo.query!("DELETE FROM inventory_maintenance_periods WHERE item_id = $1", [item_id])
    Repo.query!("DELETE FROM inventory_item_property_values WHERE item_id = $1", [item_id])
    Repo.query!("DELETE FROM inventory_items WHERE id = $1", [item_id])

    Repo.query!("DELETE FROM containers WHERE id = $1", [
      Ecto.UUID.dump!(context.container_id)
    ])

    Repo.query!("DELETE FROM equipment_categories WHERE id = $1", [
      Ecto.UUID.dump!(context.category.id)
    ])
  end

  # Runs the given operations at genuinely the same time on separate
  # connections, so the interlocks are settled by Postgres rather than by
  # test-process ordering.
  defp race(funs) when is_list(funs) do
    funs
    |> Task.async_stream(fn fun -> outside_sandbox(fun) end,
      max_concurrency: length(funs),
      ordered: true,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp outside_sandbox(fun), do: Sandbox.unboxed_run(Repo, fun)

  # ── Assertions on raw rows ──────────────────────────────────────

  defp pending_count(item) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM inventory_loans WHERE item_id = $1 AND status = 'requested'",
        [Ecto.UUID.dump!(item.id)]
      )

    count
  end

  defp active_allocation_count(item) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM inventory_loans WHERE item_id = $1 AND status IN ('approved', 'checked_out')",
        [Ecto.UUID.dump!(item.id)]
      )

    count
  end

  # Ages or shifts a loan's approved dates. No command may move a date into
  # the past for an already-approved loan the way these tests need, so the
  # fixture writes the row directly.
  defp set_approved_dates!(loan_id, starts_on, due_on) do
    Repo.query!(
      "UPDATE inventory_loans SET approved_start_on = $1, approved_due_on = $2 WHERE id = $3",
      [starts_on, due_on, Ecto.UUID.dump!(loan_id)]
    )
  end

  # ── Fixtures ────────────────────────────────────────────────────

  defp fixture do
    category = create_category!()
    container = create_container!()
    {:ok, item} = create_operator_item(container.id, category.id)

    %{category: category, container_id: container.id, item: item}
  end

  defp create_item! do
    {:ok, item} = create_operator_item(create_container!().id, create_category!().id)
    item
  end

  defp create_operator_item(container_id, category_id) do
    Inventory.create_operator_item(
      %{"container_id" => container_id, "category_id" => category_id},
      principal_id()
    )
  end

  defp request(item, borrower_id, starts_on \\ nil, due_on \\ nil) do
    starts_on = starts_on || ClubCalendar.today()
    due_on = due_on || Date.add(starts_on, 7)

    Inventory.request_loan(
      item.slug,
      %{"startsOn" => Date.to_iso8601(starts_on), "dueOn" => Date.to_iso8601(due_on)},
      borrower_id
    )
  end

  defp check_out(loan_id), do: Inventory.check_out_loan(loan_id, %{}, principal_id())

  defp create_category! do
    {:ok, category} =
      Inventory.create_category(%{
        "name" => "Operator loan category #{System.unique_integer([:positive])}"
      })

    category
  end

  defp create_container! do
    {:ok, container} =
      Inventory.create_container(
        %{"name" => "Operator loan container #{System.unique_integer([:positive])}"},
        principal_id()
      )

    container
  end

  defp principal_id do
    %Principal{id: Ecto.UUID.generate()}
    |> Principal.email_changeset(%{
      email: "operator-loans-#{System.unique_integer([:positive])}@example.com"
    })
    |> Repo.insert!()
    |> Map.fetch!(:id)
  end
end
