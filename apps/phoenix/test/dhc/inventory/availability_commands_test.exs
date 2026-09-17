defmodule Dhc.Inventory.AvailabilityCommandsTest do
  @moduledoc """
  GH-508: the one transaction boundary for every availability-changing
  inventory command.

  Exercises `Dhc.Inventory.AvailabilityCommands.execute/2` directly against
  PostgreSQL. The role facades (`OperatorLoans`, `MemberLoans`,
  `OperatorItemLifecycle`) are thin over this boundary, so the protocol —
  item lock before loan lock, re-read under the lock, availability derived
  from facts, constraint translation, actor-appropriate projection — is
  proven here once rather than per facade.

  Concurrency note: the races run on real independent connections through
  `Ecto.Adapters.SQL.Sandbox.unboxed_run/2`, so Postgres settles them rather
  than test-process ordering. That commits outside the test-owner
  transaction, so each race builds its fixture and deletes its rows
  explicitly (docs/agents/critical-patterns.md, "Real PostgreSQL Concurrency
  Tests"). Each asserts what must hold under *any* interleaving: one valid
  terminal outcome, and the loser gets a domain conflict rather than a
  server error.
  """

  use Dhc.DataCase, async: false

  alias Dhc.Auth.Principal
  alias Dhc.Inventory
  alias Dhc.Inventory.AvailabilityCommands
  alias Dhc.Inventory.ClubCalendar
  alias Dhc.Repo
  alias Ecto.Adapters.SQL.Sandbox

  # ── Actor authorization ─────────────────────────────────────────

  describe "actor authorization" do
    test "member commands refuse an operator actor and vice versa" do
      %{item: item} = fixture()
      member = principal_id()
      operator = principal_id()
      {:ok, {:loan, request}} = request(item, member)

      assert {:error, :forbidden} =
               AvailabilityCommands.execute(
                 {:operator, operator},
                 {:request_loan, item.slug, dates()}
               )

      assert {:error, :forbidden} =
               AvailabilityCommands.execute({:member, member}, {:approve_loan, request.id, %{}})

      assert {:error, :forbidden} =
               AvailabilityCommands.execute({:member, member}, {:open_maintenance, item.id, %{}})

      assert {:error, :forbidden} =
               AvailabilityCommands.execute(:system, {:approve_loan, request.id, %{}})

      # Nothing was decided before authorization: the request is still pending.
      assert loan_status(request.id) == "requested"
    end
  end

  # ── Member request ──────────────────────────────────────────────

  describe "request_loan" do
    test "succeeds only for an actionable item and projects the member view" do
      %{item: item} = fixture()
      member = principal_id()

      assert {:ok, {:loan, loan}} = request(item, member)
      assert loan.status == "requested"
      assert loan.item_slug == item.slug
      # The member projection never names a borrower or an operator.
      refute Map.has_key?(loan, :borrower_principal_id)
      refute Map.has_key?(loan, :decided_by_principal_id)
      # Nor the location before approval (story 15).
      assert loan.container_path == nil

      assert {:ok, _} = open_maintenance(item)
      assert {:error, :item_unavailable} = request(item, principal_id())

      archived = create_item!()
      assert {:ok, _} = retire(archived)
      assert {:error, :not_found} = request(archived, principal_id())
      assert {:error, :not_found} = request(%{slug: "no-such-item"}, principal_id())
    end

    test "applies the club calendar and date policy" do
      %{item: item} = fixture()
      today = ClubCalendar.today()

      assert {:ok, {:loan, same_day}} =
               request(item, principal_id(), today, today)

      assert same_day.requested_start_on == today

      assert {:error, :invalid_dates} =
               request(item, principal_id(), Date.add(today, -1), Date.add(today, 3))

      assert {:error, :invalid_dates} =
               request(item, principal_id(), Date.add(today, 3), Date.add(today, 1))

      assert {:error, :invalid_dates} =
               AvailabilityCommands.execute(
                 {:member, principal_id()},
                 {:request_loan, item.slug, %{"startsOn" => "nope"}}
               )

      assert {:error, :invalid_note} =
               AvailabilityCommands.execute(
                 {:member, principal_id()},
                 {:request_loan, item.slug, Map.put(dates(), "note", 42)}
               )
    end

    test "translates the pending-request index into a stable domain error" do
      %{item: item} = fixture()
      member = principal_id()

      assert {:ok, _} = request(item, member)
      assert {:error, :duplicate_request} = request(item, member)
      assert {:ok, _} = request(item, principal_id())
    end
  end

  # ── Member cancel ───────────────────────────────────────────────

  describe "cancel_request" do
    test "is restricted to the owning member and idempotent" do
      %{item: item} = fixture()
      owner = principal_id()
      other = principal_id()
      {:ok, {:loan, loan}} = request(item, owner)

      assert {:error, :not_found} = cancel_request(loan.id, other)
      assert loan_status(loan.id) == "requested"

      assert {:ok, {:loan, cancelled}} = cancel_request(loan.id, owner)
      assert cancelled.status == "cancelled"
      assert {:ok, {:loan, again}} = cancel_request(loan.id, owner)
      assert again.status == "cancelled"
    end

    test "releases an approved loan but not a checked-out one" do
      %{item: item} = fixture()
      owner = principal_id()
      {:ok, {:loan, loan}} = request(item, owner)
      assert {:ok, _} = approve(loan.id)

      assert {:ok, {:loan, released}} = cancel_request(loan.id, owner)
      assert released.status == "cancelled"
      assert active_allocation_count(item) == 0

      {:ok, {:loan, second}} = request(item, owner)
      assert {:ok, _} = approve(second.id)
      assert {:ok, _} = check_out(second.id)
      assert {:error, :not_cancellable} = cancel_request(second.id, owner)
    end
  end

  # ── Operator decisions ──────────────────────────────────────────

  describe "approve_loan and reject_loan" do
    test "obey current state and date policy" do
      %{item: item} = fixture()
      today = ClubCalendar.today()
      {:ok, {:loan, request}} = request(item, principal_id(), today, Date.add(today, 3))

      assert {:error, :invalid_dates} =
               approve(request.id, %{
                 "startsOn" => Date.to_iso8601(Date.add(today, 5)),
                 "dueOn" => Date.to_iso8601(Date.add(today, 1))
               })

      # A past approved start is legal: the operator records what happened.
      assert {:ok, {:loan, approved}} =
               approve(request.id, %{"startsOn" => Date.to_iso8601(Date.add(today, -2))})

      assert approved.approved_start_on == Date.add(today, -2)
      assert approved.approved_due_on == Date.add(today, 3)

      assert {:error, :not_pending} = approve(request.id)
      assert {:error, :not_pending} = reject(request.id)
      assert {:error, :not_found} = approve(Ecto.UUID.generate())
      assert {:error, :not_found} = approve("not-a-uuid")
    end

    test "approval reserves the item once and rejects competitors; rejection reserves nothing" do
      %{item: item} = fixture()
      loser = principal_id()
      {:ok, {:loan, winning}} = request(item, principal_id())
      {:ok, {:loan, losing}} = request(item, loser)

      assert {:ok, {:loan, approved}} = approve(winning.id)
      assert approved.container_path != nil
      assert loan_status(losing.id) == "rejected"
      assert active_allocation_count(item) == 1
      assert {:error, :item_unavailable} = request(item, principal_id())

      other = create_item!()
      {:ok, {:loan, pending}} = request(other, principal_id())
      operator = principal_id()

      assert {:ok, {:loan, rejected}} = reject(pending.id, %{"note" => "  Course  "}, operator)
      assert rejected.status == "rejected"
      assert rejected.decision_note == "Course"
      assert rejected.decided_by_principal_id == operator
      assert {:ok, _} = request(other, principal_id())
    end

    test "approval refuses an item that maintenance or archival made unavailable" do
      %{item: item} = fixture()
      {:ok, {:loan, request}} = request(item, principal_id())
      # Written outside the seam so the pending row survives: maintenance
      # opened through the command would have rejected it already.
      insert_open_period!(item.id, principal_id())

      assert {:error, :item_unavailable} = approve(request.id)
    end
  end

  describe "cancel_loan (operator)" do
    test "applies only to an approved loan" do
      %{item: item} = fixture()
      {:ok, {:loan, loan}} = request(item, principal_id())

      assert {:error, :not_approved} = cancel_loan(loan.id)
      assert {:ok, _} = approve(loan.id)
      assert {:ok, {:loan, cancelled}} = cancel_loan(loan.id, %{"note" => "Needed"})
      assert cancelled.status == "cancelled"
      assert cancelled.decision_note == "Needed"
      assert active_allocation_count(item) == 0
    end
  end

  # ── Checkout, return, dates ─────────────────────────────────────

  describe "check_out_loan" do
    test "is gated to the approved window in club-calendar days and to no open maintenance" do
      %{item: item} = fixture()
      today = ClubCalendar.today()
      {:ok, {:loan, loan}} = request(item, principal_id(), today, Date.add(today, 3))

      assert {:error, :not_approved} = check_out(loan.id)
      assert {:ok, _} = approve(loan.id, %{"startsOn" => Date.to_iso8601(Date.add(today, 1))})
      assert {:error, :outside_window} = check_out(loan.id)

      assert {:ok, _} = edit_dates(loan.id, %{"startsOn" => Date.to_iso8601(today)})
      set_approved_dates!(loan.id, Date.add(today, -3), Date.add(today, -1))
      assert {:error, :outside_window} = check_out(loan.id)

      # Both boundary days are inside the window.
      set_approved_dates!(loan.id, today, today)
      insert_open_period!(item.id, principal_id())
      assert {:error, :maintenance_open} = check_out(loan.id)
      close_periods!(item.id)

      assert {:ok, {:loan, out}} = check_out(loan.id)
      assert out.status == "checked_out"
      assert out.checked_out_at != nil
      assert {:error, :not_approved} = check_out(loan.id)
    end
  end

  describe "return_loan" do
    test "releases a checked-out item and refuses any other state" do
      %{item: item} = fixture()
      {:ok, {:loan, loan}} = request(item, principal_id())

      assert {:error, :not_checked_out} = return(loan.id)
      assert {:ok, _} = approve(loan.id)
      assert {:error, :not_checked_out} = return(loan.id)
      assert {:ok, _} = check_out(loan.id)
      operator = principal_id()

      assert {:ok, {:loan, returned}} = return(loan.id, operator)
      assert returned.status == "returned"
      assert returned.returned_by_principal_id == operator
      assert active_allocation_count(item) == 0
      assert {:error, :not_checked_out} = return(loan.id)
    end
  end

  describe "edit_loan_dates" do
    test "keeps the start editable before checkout and immutable after; due never precedes handover" do
      %{item: item} = fixture()
      today = ClubCalendar.today()
      {:ok, {:loan, loan}} = request(item, principal_id(), today, Date.add(today, 7))

      assert {:error, :not_editable} = edit_dates(loan.id, %{"dueOn" => Date.to_iso8601(today)})
      assert {:ok, _} = approve(loan.id)

      assert {:ok, {:loan, moved}} =
               edit_dates(loan.id, %{"startsOn" => Date.to_iso8601(Date.add(today, 1))})

      assert moved.approved_start_on == Date.add(today, 1)

      assert {:error, :invalid_dates} =
               edit_dates(loan.id, %{"dueOn" => Date.to_iso8601(Date.add(today, -1))})

      set_approved_dates!(loan.id, Date.add(today, -5), Date.add(today, 7))
      assert {:ok, _} = check_out(loan.id)

      assert {:error, :start_immutable} =
               edit_dates(loan.id, %{"startsOn" => Date.to_iso8601(today)})

      # Restating the start is not a move.
      assert {:ok, _} = edit_dates(loan.id, %{"startsOn" => Date.to_iso8601(Date.add(today, -5))})

      # Ordered after the approved start but before the handover day: refused.
      assert {:error, :invalid_dates} =
               edit_dates(loan.id, %{"dueOn" => Date.to_iso8601(Date.add(today, -2))})

      # The handover day itself is legal.
      assert {:ok, {:loan, same_day}} = edit_dates(loan.id, %{"dueOn" => Date.to_iso8601(today)})
      assert same_day.approved_due_on == today
      assert same_day.overdue? == false
    end
  end

  # ── Item lifecycle ──────────────────────────────────────────────

  describe "open_maintenance and close_maintenance" do
    test "maintenance cannot open against an active allocation and rejects pending requests" do
      %{item: item} = fixture()
      {:ok, {:loan, pending}} = request(item, principal_id())
      {:ok, {:loan, other}} = request(item, principal_id())
      assert {:ok, _} = approve(pending.id)

      assert {:error, :loan_active} = open_maintenance(item)
      assert {:ok, _} = cancel_loan(pending.id)
      # Re-request so a pending row exists when maintenance opens.
      {:ok, {:loan, fresh}} = request(item, principal_id())
      assert loan_status(other.id) == "rejected"

      assert {:error, :reason_required} = open_maintenance(item, %{"reason" => "   "})
      assert {:ok, {:item, maintained}} = open_maintenance(item, %{"reason" => "Bent"})
      assert maintained.availability == %{available?: false, status: :maintenance}
      assert loan_status(fresh.id) == "rejected"

      assert {:error, :maintenance_open} = open_maintenance(item)
      assert {:ok, {:item, closed}} = close_maintenance(item, %{"endNote" => "  Fixed "})
      assert closed.availability == %{available?: true, status: :available}
      assert [%{open?: false, end_note: "Fixed"}] = periods(item)
      assert {:error, :no_open_maintenance} = close_maintenance(item)
    end

    test "an out-of-seam open period is a domain conflict, not a raise" do
      %{item: item} = fixture()
      insert_open_period!(item.id, principal_id())

      assert {:error, :maintenance_open} = open_maintenance(item)
    end

    test "archived items are read-only" do
      %{item: item} = fixture()
      assert {:ok, _} = retire(item)

      assert {:error, :archived} = open_maintenance(item)
      assert {:error, :archived} = close_maintenance(item)
      assert {:error, :archived} = move(item, create_container!().id)
    end
  end

  describe "retire_item and reactivate_item" do
    test "retirement is blocked by an active allocation, closes maintenance, and is idempotent" do
      %{item: item} = fixture()
      {:ok, {:loan, loan}} = request(item, principal_id())
      assert {:ok, _} = approve(loan.id)
      assert {:error, :loan_active} = retire(item)

      assert {:ok, _} = cancel_loan(loan.id)
      {:ok, {:loan, pending}} = request(item, principal_id())
      assert {:ok, _} = open_maintenance(item)
      # Maintenance rejected the pending request; re-request would be refused,
      # so prove archival's own rejection with an out-of-seam pending row.
      assert loan_status(pending.id) == "rejected"

      assert {:ok, {:item, archived}} = retire(item, %{"reason" => "Worn out"})
      assert archived.availability == %{available?: false, status: :archived}
      assert [%{open?: false, end_note: "Archived: Worn out"}] = periods(item)
      assert {:ok, {:item, again}} = retire(item)
      assert again.archived_at == archived.archived_at
    end

    test "reactivation is gated on dependencies and idempotent" do
      %{item: item, category: category} = fixture()
      assert {:ok, {:item, active}} = reactivate(item)
      assert active.archived_at == nil

      assert {:ok, _} = retire(item)
      set_category_archived!(category.id, true)
      assert {:error, :archived_category} = reactivate(item)
      set_category_archived!(category.id, false)

      assert {:ok, {:item, restored}} = reactivate(item)
      assert restored.archived_at == nil
      assert restored.availability == %{available?: true, status: :available}
    end
  end

  describe "move_item" do
    test "is blocked by an active loan, allowed in maintenance, and only touches the container" do
      %{item: item} = fixture()
      destination = create_container!()
      {:ok, {:loan, loan}} = request(item, principal_id())
      assert {:ok, _} = approve(loan.id)

      assert {:error, :loan_active} = move(item, destination.id)
      assert {:ok, _} = cancel_loan(loan.id)
      assert {:ok, _} = open_maintenance(item)

      assert {:ok, {:item, moved}} = move(item, destination.id)
      assert moved.container_id == destination.id
      assert {:error, :not_found} = move(item, Ecto.UUID.generate())
      assert {:error, :not_found} = move(item, nil)
    end
  end

  # ── Projections and side effects ────────────────────────────────

  describe "outcomes" do
    test "operator and member outcomes expose only their intended projection" do
      %{item: item} = fixture()
      member = principal_id()
      {:ok, {:loan, requested}} = request(item, member)
      {:ok, {:loan, approved}} = approve(requested.id)

      assert Map.has_key?(approved, :borrower_principal_id)
      assert Map.has_key?(approved, :decided_by_principal_id)
      assert approved.container_path != nil

      {:ok, {:loan, cancelled}} = cancel_request(requested.id, member)
      refute Map.has_key?(cancelled, :borrower_principal_id)
      refute Map.has_key?(cancelled, :decided_by_principal_id)
      # Member view discloses the path only from approval onward; a cancelled
      # loan was never collectable, so it is withheld.
      assert cancelled.container_path == nil
    end

    test "commands emit no notifications" do
      %{item: item} = fixture()
      member = principal_id()
      {:ok, {:loan, loan}} = request(item, member)
      {:ok, _} = approve(loan.id)

      {:ok, _} =
        edit_dates(loan.id, %{"dueOn" => Date.to_iso8601(Date.add(loan.requested_due_on, 2))})

      {:ok, _} = check_out(loan.id)
      {:ok, _} = return(loan.id)
      {:ok, _} = open_maintenance(item)
      {:ok, _} = close_maintenance(item)
      {:ok, _} = retire(item)

      assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM notifications", [])
    end
  end

  # ── Concurrency ─────────────────────────────────────────────────

  describe "concurrency" do
    test "competing member requests from one member yield one winner; from two members both land" do
      committed(fn %{item: item} ->
        member = principal_id()
        results = race([fn -> request(item, member) end, fn -> request(item, member) end])
        assert Enum.count(results, &match?({:ok, _}, &1)) == 1
        assert Enum.count(results, &match?({:error, :duplicate_request}, &1)) == 1

        others =
          race([fn -> request(item, principal_id()) end, fn -> request(item, principal_id()) end])

        assert Enum.all?(others, &match?({:ok, _}, &1))
        assert pending_count(item) == 3
      end)
    end

    test "two approvals of competing requests reserve the item exactly once" do
      committed(fn %{item: item} ->
        {:ok, {:loan, first}} = request(item, principal_id())
        {:ok, {:loan, second}} = request(item, principal_id())

        results = race([fn -> approve(first.id) end, fn -> approve(second.id) end])

        assert Enum.count(results, &match?({:ok, _}, &1)) == 1

        assert Enum.count(results, fn
                 {:error, reason} -> reason in [:already_allocated, :not_pending]
                 _other -> false
               end) == 1

        assert active_allocation_count(item) == 1
      end)
    end

    test "checkout cannot race maintenance opening" do
      committed(fn %{item: item} ->
        {:ok, {:loan, loan}} = request(item, principal_id())
        {:ok, _} = approve(loan.id)

        [checkout, maintenance] =
          race([fn -> check_out(loan.id) end, fn -> open_maintenance(item) end])

        # An approved loan blocks maintenance either way; if maintenance had
        # somehow opened first, checkout must have seen it.
        case {checkout, maintenance} do
          {{:ok, _}, {:error, :loan_active}} -> assert loan_status(loan.id) == "checked_out"
          {{:error, :maintenance_open}, {:ok, _}} -> assert loan_status(loan.id) == "approved"
        end
      end)
    end

    test "maintenance cannot open against an allocation being approved" do
      committed(fn %{item: item} ->
        {:ok, {:loan, loan}} = request(item, principal_id())

        [approval, maintenance] =
          race([fn -> approve(loan.id) end, fn -> open_maintenance(item) end])

        case {approval, maintenance} do
          {{:ok, _}, {:error, :loan_active}} ->
            assert active_allocation_count(item) == 1
            assert periods(item) == []

          {{:error, reason}, {:ok, _}} ->
            assert reason in [:not_pending, :item_unavailable]
            assert active_allocation_count(item) == 0
            assert [%{open?: true}] = periods(item)
        end
      end)
    end

    test "return and retirement races preserve one valid terminal outcome" do
      committed(fn %{item: item} ->
        {:ok, {:loan, loan}} = request(item, principal_id())
        {:ok, _} = approve(loan.id)
        {:ok, _} = check_out(loan.id)

        [returned, retired] = race([fn -> return(loan.id) end, fn -> retire(item) end])

        assert match?({:ok, _}, returned)
        assert {:ok, resolved} = Inventory.resolve_operator_item(item.id)

        case retired do
          {:ok, _} -> assert resolved.archived_at != nil
          {:error, :loan_active} -> assert resolved.archived_at == nil
        end

        assert loan_status(loan.id) == "returned"
      end)
    end

    test "loan commands lock the item before the loan so a member cancel and an approval queue rather than deadlock" do
      committed(fn %{item: item} ->
        member = principal_id()
        {:ok, {:loan, loan}} = request(item, member)

        [approval, cancellation] =
          race([fn -> approve(loan.id) end, fn -> cancel_request(loan.id, member) end])

        assert match?({:ok, _}, approval) or match?({:error, :not_pending}, approval)
        assert match?({:ok, _}, cancellation) or match?({:error, :not_cancellable}, cancellation)
        assert loan_status(loan.id) in ~w(approved cancelled)

        expected = if loan_status(loan.id) == "approved", do: 1, else: 0
        assert active_allocation_count(item) == expected
      end)
    end

    test "every other loan command queues behind the item lock too, against a member cancel and a maintenance start" do
      committed(fn %{item: item} ->
        # Each command is raced from the state it needs, against a member
        # cancellation (item → loan order) and a maintenance start (item
        # only). A deadlock would surface as a Postgrex error or a pool
        # timeout; a lock-order bug cannot hide behind a lucky interleaving
        # forever, so every command is exercised.
        scenarios = [
          {"requested", fn loan -> reject(loan.id) end},
          {"approved", fn loan -> cancel_loan(loan.id) end},
          {"approved", fn loan -> edit_dates(loan.id, %{"dueOn" => far_due()}) end},
          {"checked_out", fn loan -> return(loan.id) end}
        ]

        for {state, command} <- scenarios do
          member = principal_id()
          loan = loan_in_state(item, member, state)

          results =
            race([
              fn -> command.(loan) end,
              fn -> cancel_request(loan.id, member) end,
              fn -> open_maintenance(item) end
            ])

          assert Enum.all?(results, &(match?({:ok, _}, &1) or match?({:error, _}, &1)))
          refute Enum.any?(results, &match?({:error, :constraint_violation}, &1))
          assert active_allocation_count(item) <= 1
          refute active_allocation_count(item) == 1 and Enum.any?(periods(item), & &1.open?)

          reset_item!(item)
        end
      end)
    end

    test "two checkouts of one approved loan hand it over once" do
      committed(fn %{item: item} ->
        {:ok, {:loan, loan}} = request(item, principal_id())
        {:ok, _} = approve(loan.id)

        results = race([fn -> check_out(loan.id) end, fn -> check_out(loan.id) end])

        assert Enum.count(results, &match?({:ok, _}, &1)) == 1
        assert Enum.count(results, &match?({:error, :not_approved}, &1)) == 1
      end)
    end

    test "two maintenance starts open one period; two retirements archive once" do
      committed(fn %{item: item} ->
        starts = race([fn -> open_maintenance(item) end, fn -> open_maintenance(item) end])
        assert Enum.count(starts, &match?({:ok, _}, &1)) == 1
        assert Enum.count(starts, &match?({:error, :maintenance_open}, &1)) == 1
        assert [%{open?: true}] = periods(item)

        retirements = race([fn -> retire(item) end, fn -> retire(item) end])
        # Retirement is idempotent, so both succeed; the period closed once.
        assert Enum.all?(retirements, &match?({:ok, _}, &1))
        assert [%{open?: false}] = periods(item)
      end)
    end

    test "a maintenance start or a move racing a retirement never lands on the archived item" do
      committed(fn %{item: item, container_id: origin, destination: destination} ->
        [start, retirement] = race([fn -> open_maintenance(item) end, fn -> retire(item) end])
        assert match?({:ok, _}, start) or match?({:error, :archived}, start)
        assert match?({:ok, _}, retirement)
        refute Enum.any?(periods(item), & &1.open?)

        {:ok, _} = reactivate(item)
        [move, second] = race([fn -> move(item, destination.id) end, fn -> retire(item) end])
        assert match?({:ok, _}, second)
        assert match?({:ok, _}, move) or match?({:error, :archived}, move)

        assert {:ok, resolved} = Inventory.resolve_operator_item(item.id)
        assert resolved.container_id in [origin, destination.id]
        assert resolved.archived_at != nil
      end)
    end

    test "an approval racing a move, a maintenance start, or a retirement leaves one consistent state" do
      committed(fn %{item: item, destination: destination} ->
        for interlock <- [
              fn -> move(item, destination.id) end,
              fn -> open_maintenance(item) end,
              fn -> retire(item) end
            ] do
          {:ok, {:loan, loan}} = request(item, principal_id())
          [approval, result] = race([fn -> approve(loan.id) end, interlock])

          case result do
            {:ok, _} ->
              # The interlock won: the request was either rejected by it or
              # the approval found it already decided.
              assert match?({:error, _}, approval) or loan_status(loan.id) == "approved"
              refute loan_status(loan.id) == "approved" and Enum.any?(periods(item), & &1.open?)

            {:error, :loan_active} ->
              assert match?({:ok, _}, approval)
              assert loan_status(loan.id) == "approved"
          end

          # Reset for the next interlock without leaving a live claim.
          reset_item!(item)
        end
      end)
    end

    test "representative contention across every command neither deadlocks nor breaks an invariant" do
      committed(fn %{item: item} ->
        members = Enum.map(1..3, fn _ -> principal_id() end)

        requests =
          Enum.map(members, fn member ->
            {:ok, {:loan, loan}} = request(item, member)
            {member, loan}
          end)

        [{owner, first} | _rest] = requests

        results =
          race(
            [
              fn -> approve(first.id) end,
              fn -> cancel_request(first.id, owner) end,
              fn -> open_maintenance(item) end,
              fn -> retire(item) end,
              fn -> request(item, principal_id()) end
            ] ++ Enum.map(requests, fn {_member, loan} -> fn -> approve(loan.id) end end)
          )

        # Every command returned a result tuple — no deadlock, no raise.
        assert Enum.all?(results, &(match?({:ok, _}, &1) or match?({:error, _}, &1)))
        assert active_allocation_count(item) <= 1
        assert Enum.count(periods(item), & &1.open?) <= 1

        {:ok, resolved} = Inventory.resolve_operator_item(item.id)

        if active_allocation_count(item) == 1 do
          refute resolved.archived_at
          refute Enum.any?(periods(item), & &1.open?)
        end

        if resolved.archived_at do
          refute Enum.any?(periods(item), & &1.open?)
          assert pending_count(item) == 0
        end
      end)
    end

    test "a stale unlocked prefetch cannot authorize a transition" do
      committed(fn %{item: item} ->
        member = principal_id()
        {:ok, {:loan, loan}} = request(item, member)

        # Hold the item lock on one connection while another operator's
        # approval is already past its unlocked "which item?" read. The
        # holder cancels the request; the approval, once it acquires the
        # item, must re-read the loan and see the cancellation.
        parent = self()

        holder =
          Task.async(fn ->
            outside_sandbox(fn ->
              Repo.transaction(fn ->
                Repo.query!("SELECT id FROM inventory_items WHERE id = $1 FOR UPDATE", [
                  Ecto.UUID.dump!(item.id)
                ])

                send(parent, :locked)
                receive do: (:release -> :ok)

                Repo.query!(
                  "UPDATE inventory_loans SET status = 'cancelled', decided_at = NOW() WHERE id = $1",
                  [Ecto.UUID.dump!(loan.id)]
                )
              end)
            end)
          end)

        assert_receive :locked, 5_000
        approval = Task.async(fn -> outside_sandbox(fn -> approve(loan.id) end) end)
        # Give the approval time to run its unlocked read and block on the item.
        :ok = wait_for_lock_waiter()
        send(holder.pid, :release)

        assert {:ok, _} = Task.await(holder, 5_000)
        assert {:error, :not_pending} = Task.await(approval, 5_000)
        assert active_allocation_count(item) == 0
      end)
    end

    test "moving into a container racing an archive of that container never raises" do
      committed(fn %{item: item, destination: destination} ->
        {:ok, child} =
          Inventory.create_container(
            %{
              "name" => "Move race child #{System.unique_integer([:positive])}",
              "parentContainerId" => destination.id
            },
            principal_id()
          )

        {:ok, _} = move(item, child.id)

        results =
          hold_lock_then(
            "SELECT id FROM containers WHERE id = $1 FOR UPDATE",
            [Ecto.UUID.dump!(destination.id)],
            [
              fn -> move(item, destination.id) end,
              fn -> Inventory.archive_container(destination.id) end
            ]
          )

        assert Enum.all?(results, &domain_outcome?/1)
      end)
    end

    test "restoring an item racing an archive of its container never raises" do
      committed(fn %{item: item, container_id: container_id} ->
        {:ok, _} = retire(item)

        results =
          hold_lock_then(
            "SELECT id FROM containers WHERE id = $1 FOR UPDATE",
            [Ecto.UUID.dump!(container_id)],
            [
              fn -> reactivate(item) end,
              fn -> Inventory.archive_container(container_id) end
            ]
          )

        assert Enum.all?(results, &domain_outcome?/1)

        {:ok, resolved} = Inventory.resolve_operator_item(item.id)
        {:ok, container} = Inventory.get_container(container_id)
        refute resolved.archived_at == nil and container.archived_at != nil
      end)
    end

    test "restore retries when the item's container changed after the unlocked peek" do
      committed(fn %{item: item, destination: destination} ->
        {:ok, _} = retire(item)
        parent = self()

        item_holder =
          Task.async(fn -> rewire_item_container(item.id, destination.id, parent) end)

        assert_receive :item_locked, 5_000

        restore = Task.async(fn -> outside_sandbox(fn -> reactivate(item) end) end)
        :ok = wait_for_lock_waiter("%inventory_items%")
        send(item_holder.pid, :rewire)
        assert_receive :rewired, 5_000

        dest_holder =
          Task.async(fn -> hold_archive_locks(destination.id, item.id, parent) end)

        assert_receive :dest_locked, 5_000
        send(item_holder.pid, :release)
        assert {:ok, _} = Task.await(item_holder, 5_000)

        :ok = wait_for_lock_waiter("%containers%")
        assert Task.yield(restore, 200) == nil

        # Archive-of-D's next lock is the item. If restore held the item
        # while requesting D, this deadlocks; if it released first, dest
        # acquires the item and restore stays queued on D.
        send(dest_holder.pid, :lock_item)
        assert_receive :dest_has_item, 5_000
        assert Task.yield(restore, 200) == nil

        send(dest_holder.pid, :release)
        assert {:ok, _} = Task.await(dest_holder, 5_000)

        assert {:ok, {:item, restored}} = Task.await(restore, 5_000)
        assert restored.container_id == destination.id
        assert restored.archived_at == nil

        {:ok, resolved} = Inventory.resolve_operator_item(item.id)
        assert resolved.container_id == destination.id
        assert resolved.archived_at == nil
      end)
    end
  end

  describe "database backstops" do
    test "the active-allocation index refuses a second live claim written outside the seam" do
      %{item: item} = fixture()
      {:ok, {:loan, loan}} = request(item, principal_id())
      assert {:ok, _} = approve(loan.id)

      assert_raise Postgrex.Error, fn -> insert_active_loan!(item, principal_id()) end
    end

    test "the one-open-period index refuses a second open period written outside the seam" do
      %{item: item} = fixture()
      assert {:ok, _} = open_maintenance(item)

      assert_raise Postgrex.Error, fn -> insert_open_period!(item.id, principal_id()) end
    end

    test "a foreign-key failure is translated rather than raised" do
      %{item: item} = fixture()
      {:ok, {:loan, loan}} = request(item, principal_id())
      assert {:ok, _} = approve(loan.id)

      # `decided_by_principal_id` references principals; an actor that does
      # not exist must be a domain error, never a `Postgrex.Error`.
      assert {:error, :unknown_actor} =
               AvailabilityCommands.execute(
                 {:operator, Ecto.UUID.generate()},
                 {:check_out_loan, loan.id, %{}}
               )

      assert loan_status(loan.id) == "approved"

      # Item writes stamp `updated_by`, which references principals too.
      free = create_item!()

      assert {:error, :unknown_actor} =
               AvailabilityCommands.execute(
                 {:operator, Ecto.UUID.generate()},
                 {:move_item, free.id, %{"containerId" => create_container!().id}}
               )

      assert {:error, :unknown_actor} =
               AvailabilityCommands.execute(
                 {:operator, Ecto.UUID.generate()},
                 {:open_maintenance, free.id, %{"reason" => "Bent"}}
               )
    end
  end

  # ── Command helpers ─────────────────────────────────────────────

  defp dates(starts_on \\ nil, due_on \\ nil) do
    starts_on = starts_on || ClubCalendar.today()
    due_on = due_on || Date.add(starts_on, 7)
    %{"startsOn" => Date.to_iso8601(starts_on), "dueOn" => Date.to_iso8601(due_on)}
  end

  defp request(item, member, starts_on \\ nil, due_on \\ nil) do
    AvailabilityCommands.execute(
      {:member, member},
      {:request_loan, item.slug, dates(starts_on, due_on)}
    )
  end

  defp cancel_request(loan_id, member),
    do: AvailabilityCommands.execute({:member, member}, {:cancel_request, loan_id, %{}})

  defp operator(command, actor \\ nil),
    do: AvailabilityCommands.execute({:operator, actor || principal_id()}, command)

  defp approve(loan_id, attrs \\ %{}), do: operator({:approve_loan, loan_id, attrs})

  defp reject(loan_id, attrs \\ %{}, actor \\ nil),
    do: operator({:reject_loan, loan_id, attrs}, actor)

  defp cancel_loan(loan_id, attrs \\ %{}), do: operator({:cancel_loan, loan_id, attrs})
  defp check_out(loan_id), do: operator({:check_out_loan, loan_id, %{}})
  defp return(loan_id, actor \\ nil), do: operator({:return_loan, loan_id, %{}}, actor)
  defp edit_dates(loan_id, attrs), do: operator({:edit_loan_dates, loan_id, attrs})

  defp open_maintenance(item, attrs \\ %{"reason" => "Servicing"}),
    do: operator({:open_maintenance, item.id, attrs})

  defp close_maintenance(item, attrs \\ %{}), do: operator({:close_maintenance, item.id, attrs})
  defp retire(item, attrs \\ %{}), do: operator({:retire_item, item.id, attrs})
  defp reactivate(item), do: operator({:reactivate_item, item.id, %{}})

  defp move(item, container_id),
    do: operator({:move_item, item.id, %{"containerId" => container_id}})

  defp periods(item), do: Inventory.list_operator_item_maintenance_periods(item.id)

  defp far_due, do: Date.to_iso8601(Date.add(ClubCalendar.today(), 30))

  # Drives a fresh loan to `state` through the real commands.
  defp loan_in_state(item, member, state) do
    {:ok, {:loan, loan}} = request(item, member)

    if state in ~w(approved checked_out), do: {:ok, _} = approve(loan.id)
    if state == "checked_out", do: {:ok, _} = check_out(loan.id)

    loan
  end

  # ── Real-concurrency helpers ───────────────────────────────────

  @principals_agent __MODULE__.CommittedPrincipals

  defp committed(fun) do
    start_principal_tracker()

    context =
      outside_sandbox(fn ->
        category = create_category!()
        container = create_container!()
        destination = create_container!()
        {:ok, item} = create_operator_item(container.id, category.id)

        %{
          category: category,
          container_id: container.id,
          destination: destination,
          item: item
        }
      end)

    # `unboxed_run` must not nest: the inner call checks the outer connection
    # back in, so every committed fixture row is created here, once.
    on_exit(fn -> outside_sandbox(fn -> cleanup_committed(context) end) end)

    outside_sandbox(fn -> fun.(context) end)
  end

  defp cleanup_committed(context) do
    item_id = Ecto.UUID.dump!(context.item.id)

    Repo.query!("DELETE FROM inventory_loans WHERE item_id = $1", [item_id])
    Repo.query!("DELETE FROM inventory_maintenance_periods WHERE item_id = $1", [item_id])
    Repo.query!("DELETE FROM inventory_item_property_values WHERE item_id = $1", [item_id])
    Repo.query!("DELETE FROM inventory_items WHERE id = $1", [item_id])

    container_ids = Enum.map([context.container_id, context.destination.id], &Ecto.UUID.dump!/1)

    Repo.query!(
      """
      WITH RECURSIVE subtree AS (
        SELECT id FROM containers WHERE id = ANY($1)
        UNION ALL
        SELECT child.id
        FROM containers child
        JOIN subtree parent ON parent.id = child.parent_container_id
      )
      DELETE FROM containers WHERE id IN (SELECT id FROM subtree)
      """,
      [container_ids]
    )

    Repo.query!("DELETE FROM equipment_categories WHERE id = $1", [
      Ecto.UUID.dump!(context.category.id)
    ])

    cleanup_principals()
  end

  defp race(funs) when is_list(funs) do
    parent = self()

    tasks =
      Enum.map(funs, fn fun ->
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> outside_sandbox(fun)
          end
        end)
      end)

    expected = MapSet.new(Enum.map(tasks, & &1.pid))

    received =
      Enum.map(tasks, fn _task ->
        assert_receive {:ready, pid}, 5_000
        pid
      end)

    assert MapSet.new(received) == expected
    Enum.each(tasks, fn task -> send(task.pid, :go) end)
    Enum.map(tasks, &Task.await(&1, :infinity))
  end

  defp domain_outcome?({:ok, _}), do: true
  defp domain_outcome?({:error, reason}) when is_atom(reason), do: true
  defp domain_outcome?({:error, %Ecto.Changeset{}}), do: true
  defp domain_outcome?(_other), do: false

  defp outside_sandbox(fun), do: Sandbox.unboxed_run(Repo, fun)

  # Hold a row lock, start the competing commands, prove they are queued
  # behind it, then release. Without the held lock a ready/go barrier can
  # let one command finish before the other opens its transaction.
  defp hold_lock_then(sql, params, funs) do
    parent = self()
    holder = Task.async(fn -> hold_row_lock(sql, params, parent) end)

    assert_receive :locked, 5_000

    tasks = Enum.map(funs, fn fun -> Task.async(fn -> outside_sandbox(fun) end) end)

    try do
      :ok = wait_for_lock_waiter("%")

      Enum.each(tasks, fn task ->
        assert Task.yield(task, 200) == nil
      end)
    after
      send(holder.pid, :release)
    end

    assert {:ok, _} = Task.await(holder, 5_000)
    Enum.map(tasks, &Task.await(&1, :infinity))
  end

  defp hold_row_lock(sql, params, parent) do
    outside_sandbox(fn ->
      Repo.transaction(fn ->
        Repo.query!(sql, params)
        send(parent, :locked)
        receive do: (:release -> :ok)
      end)
    end)
  end

  defp rewire_item_container(item_id, destination_id, parent) do
    outside_sandbox(fn ->
      Repo.transaction(fn ->
        Repo.query!("SELECT id FROM inventory_items WHERE id = $1 FOR UPDATE", [
          Ecto.UUID.dump!(item_id)
        ])

        send(parent, :item_locked)
        receive do: (:rewire -> :ok)

        Repo.query!("UPDATE inventory_items SET container_id = $1 WHERE id = $2", [
          Ecto.UUID.dump!(destination_id),
          Ecto.UUID.dump!(item_id)
        ])

        send(parent, :rewired)
        receive do: (:release -> :ok)
      end)
    end)
  end

  # Archive locks the container first, then the item beneath it. Holding
  # both in that order is how we detect a restore that inverted them.
  # The container lock is `FOR NO KEY UPDATE` so it can be taken while
  # the rewire still holds an inbound FK KEY SHARE on D.
  defp hold_archive_locks(destination_id, item_id, parent) do
    outside_sandbox(fn ->
      Repo.transaction(fn ->
        # `FOR UPDATE` would wait on the rewire's inbound FK KEY SHARE.
        # `FOR NO KEY UPDATE` still conflicts with restore's FOR SHARE.
        Repo.query!("SELECT id FROM containers WHERE id = $1 FOR NO KEY UPDATE", [
          Ecto.UUID.dump!(destination_id)
        ])

        send(parent, :dest_locked)
        receive do: (:lock_item -> :ok)

        Repo.query!("SELECT id FROM inventory_items WHERE id = $1 FOR UPDATE", [
          Ecto.UUID.dump!(item_id)
        ])

        send(parent, :dest_has_item)
        receive do: (:release -> :ok)
      end)
    end)
  end

  # Blocks — inside Postgres, not the test process — until some other
  # backend is waiting on an ungranted lock whose `query` matches the
  # LIKE pattern. A backend's wait state is only observable from
  # `pg_locks` / `pg_stat_activity`, so the wait lives in one SQL
  # statement with its own cap rather than in an Elixir sleep loop.
  defp wait_for_lock_waiter(query_pattern \\ "%inventory_items%") when is_binary(query_pattern) do
    Repo.query!(
      """
      DO $$
      DECLARE attempts int := 0;
      BEGIN
        LOOP
          EXIT WHEN EXISTS (
            SELECT 1
            FROM pg_locks blocked
            JOIN pg_stat_activity a ON a.pid = blocked.pid
            WHERE NOT blocked.granted
              AND blocked.pid <> pg_backend_pid()
              AND a.query ILIKE '#{query_pattern}'
          );
          attempts := attempts + 1;
          IF attempts > 500 THEN
            RAISE EXCEPTION 'no backend queued behind the held lock';
          END IF;
          PERFORM pg_sleep(0.01);
          -- Activity stats are snapshotted per transaction; refresh them or
          -- the loop would never observe the waiter arriving.
          PERFORM pg_stat_clear_snapshot();
        END LOOP;
      END
      $$
      """,
      []
    )

    :ok
  end

  defp start_principal_tracker do
    case Process.whereis(@principals_agent) do
      nil -> {:ok, _pid} = Agent.start_link(fn -> [] end, name: @principals_agent)
      _pid -> Agent.update(@principals_agent, fn _ids -> [] end)
    end
  end

  defp track_principal(id) do
    case Process.whereis(@principals_agent) do
      nil -> :ok
      _pid -> Agent.update(@principals_agent, &[id | &1])
    end
  end

  defp cleanup_principals do
    ids =
      case Process.whereis(@principals_agent) do
        nil -> []
        _pid -> Agent.get(@principals_agent, & &1)
      end

    if ids != [] do
      Repo.query!("DELETE FROM principals WHERE id = ANY($1::uuid[])", [ids])
    end
  end

  # ── Raw-row helpers ─────────────────────────────────────────────

  defp loan_status(loan_id) do
    %{rows: [[status]]} =
      Repo.query!("SELECT status FROM inventory_loans WHERE id = $1", [Ecto.UUID.dump!(loan_id)])

    status
  end

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

  defp set_approved_dates!(loan_id, starts_on, due_on) do
    Repo.query!(
      "UPDATE inventory_loans SET approved_start_on = $1, approved_due_on = $2 WHERE id = $3",
      [starts_on, due_on, Ecto.UUID.dump!(loan_id)]
    )
  end

  defp insert_open_period!(item_id, principal_id) do
    Repo.query!(
      """
      INSERT INTO inventory_maintenance_periods
        (item_id, started_at, started_by_principal_id, start_reason, created_at, updated_at)
      VALUES ($1, NOW(), $2, 'outside the seam', NOW(), NOW())
      """,
      [Ecto.UUID.dump!(item_id), Ecto.UUID.dump!(principal_id)]
    )
  end

  defp close_periods!(item_id) do
    Repo.query!(
      "UPDATE inventory_maintenance_periods SET ended_at = NOW() WHERE item_id = $1 AND ended_at IS NULL",
      [Ecto.UUID.dump!(item_id)]
    )
  end

  # Puts a raced item back to available with no live claim, so the next race
  # in a loop starts from the same state. Raw SQL because no command may
  # "undo" an approval or a rejection.
  defp reset_item!(item) do
    item_id = Ecto.UUID.dump!(item.id)
    Repo.query!("UPDATE inventory_loans SET status = 'cancelled' WHERE item_id = $1", [item_id])
    close_periods!(item.id)

    Repo.query!(
      "UPDATE inventory_items SET archived_at = NULL, archived_by_principal_id = NULL WHERE id = $1",
      [item_id]
    )
  end

  # ── Fixtures ────────────────────────────────────────────────────

  defp set_category_archived!(category_id, true) do
    Repo.query!("UPDATE equipment_categories SET archived_at = NOW() WHERE id = $1", [
      Ecto.UUID.dump!(category_id)
    ])
  end

  defp set_category_archived!(category_id, false) do
    Repo.query!("UPDATE equipment_categories SET archived_at = NULL WHERE id = $1", [
      Ecto.UUID.dump!(category_id)
    ])
  end

  defp insert_active_loan!(item, borrower_id) do
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
      [Ecto.UUID.dump!(item.id), Ecto.UUID.dump!(borrower_id), item.slug]
    )
  end

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

  defp create_category! do
    {:ok, category} =
      Inventory.create_category(%{
        "name" => "Availability category #{System.unique_integer([:positive])}"
      })

    category
  end

  defp create_container! do
    {:ok, container} =
      Inventory.create_container(
        %{"name" => "Availability container #{System.unique_integer([:positive])}"},
        principal_id()
      )

    container
  end

  defp principal_id do
    id =
      %Principal{id: Ecto.UUID.generate()}
      |> Principal.email_changeset(%{
        email: "availability-#{System.unique_integer([:positive])}@example.com"
      })
      |> Repo.insert!()
      |> Map.fetch!(:id)

    track_principal(id)
    id
  end
end
