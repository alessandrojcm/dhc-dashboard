defmodule Dhc.Inventory.OperatorLoanQueueTest do
  @moduledoc """
  ALE-297 (ALE-286b): the shared operator loan queue.

  Proves through `Dhc.Inventory` that every open loan lands in exactly one
  bucket at each lifecycle position, that each bucket's count is its own rows,
  that the due-date boundaries are the club calendar's days, and — as its own
  concern — that the operator projection stays operator-only.

  Loans reach their positions through the real member and operator commands
  (`request_loan/3`, `approve_loan/3`, `check_out_loan/3`), so the queue is
  proven to read what the lifecycle actually writes rather than what a SQL
  fixture claims. Direct SQL appears only to age a loan's approved dates,
  which no command may do (`edit_loan_dates/3` refuses a due date before the
  handover, and nothing may move an approved window wholly into the past).
  """

  use Dhc.DataCase, async: false

  alias Dhc.Auth.Principal
  alias Dhc.Inventory
  alias Dhc.Inventory.ClubCalendar
  alias Dhc.Repo

  # ── Bucket membership ───────────────────────────────────────────

  describe "bucket membership by lifecycle position" do
    test "a pending request sits only in the requests bucket" do
      %{item: item} = fixture()
      {:ok, request} = request(item, principal_id())

      queue = Inventory.get_operator_loan_queue()

      assert ids(queue.pending_requests) == [request.id]
      assert queue.handovers_due.rows == []
      assert queue.returns_and_overdue.rows == []
    end

    test "an approved loan moves to the handovers bucket" do
      %{item: item} = fixture()
      {:ok, request} = request(item, principal_id())
      assert {:ok, _} = Inventory.approve_loan(request.id, %{}, principal_id())

      queue = Inventory.get_operator_loan_queue()

      assert queue.pending_requests.rows == []
      assert ids(queue.handovers_due) == [request.id]
      assert queue.returns_and_overdue.rows == []
    end

    test "a checked-out loan moves to the returns bucket" do
      %{item: item} = fixture()
      {:ok, request} = request(item, principal_id())
      assert {:ok, _} = Inventory.approve_loan(request.id, %{}, principal_id())
      assert {:ok, _} = Inventory.check_out_loan(request.id, %{}, principal_id())

      queue = Inventory.get_operator_loan_queue()

      assert queue.pending_requests.rows == []
      assert queue.handovers_due.rows == []
      assert ids(queue.returns_and_overdue) == [request.id]
    end

    test "a closed loan leaves the queue entirely" do
      today = ClubCalendar.today()

      rejected = closed_loan(fn id -> Inventory.reject_loan(id, %{}, principal_id()) end)

      cancelled =
        closed_loan(fn id ->
          {:ok, _} = Inventory.approve_loan(id, %{}, principal_id())
          Inventory.cancel_operator_loan(id, %{}, principal_id())
        end)

      returned =
        closed_loan(fn id ->
          {:ok, _} = Inventory.approve_loan(id, %{}, principal_id())
          {:ok, _} = Inventory.check_out_loan(id, %{}, principal_id())
          Inventory.return_loan(id, principal_id())
        end)

      # A closed loan is finished work, and a returned loan is never overdue
      # however late it was — the queue is the next physical action, not a log.
      set_approved_dates!(returned, Date.add(today, -30), Date.add(today, -20))

      queue = Inventory.get_operator_loan_queue()

      for id <- [rejected, cancelled, returned] do
        refute id in every_loan_id(queue)
      end
    end

    test "a member cancelling their own request removes it from the queue" do
      %{item: item} = fixture()
      member = principal_id()
      {:ok, request} = request(item, member)

      assert request.id in ids(Inventory.get_operator_loan_queue().pending_requests)

      assert {:ok, _} = Inventory.cancel_loan(request.id, %{}, member)

      refute request.id in every_loan_id(Inventory.get_operator_loan_queue())
    end

    test "one loan is never in two buckets at once" do
      today = ClubCalendar.today()

      pending = requested_loan()
      handover = approved_loan()
      lapsed = lapsed_handover(today)
      out = checked_out_loan()
      overdue = overdue_loan(today)

      queue = Inventory.get_operator_loan_queue()
      seen = every_loan_id(queue)

      assert Enum.sort(seen) == Enum.sort(Enum.uniq(seen))
      assert Enum.sort(seen) == Enum.sort([pending, handover, lapsed, out, overdue])
    end
  end

  # ── Counts ──────────────────────────────────────────────────────

  describe "counts" do
    test "each bucket's count is the length of its own rows" do
      today = ClubCalendar.today()

      requested_loan()
      requested_loan()
      approved_loan()
      lapsed_handover(today)
      checked_out_loan()
      maintained_item()

      queue = Inventory.get_operator_loan_queue()

      # A count is derived from the rows it sits beside, so it cannot report a
      # number the operator's own list contradicts.
      for bucket <- buckets(queue) do
        assert bucket.count == length(bucket.rows)
      end

      assert queue.pending_requests.count == 2
      assert queue.handovers_due.count == 2
      assert queue.returns_and_overdue.count == 1
      assert queue.open_maintenance.count == 1
    end

    test "an empty queue reports zero for every bucket" do
      queue = Inventory.get_operator_loan_queue()

      for bucket <- buckets(queue) do
        assert bucket.count == 0
        assert bucket.rows == []
      end
    end
  end

  # ── Due-date boundaries ─────────────────────────────────────────

  describe "handover readiness at the club-calendar boundaries" do
    test "an approved loan starting today is due and ready" do
      %{item: item} = fixture()
      today = ClubCalendar.today()
      {:ok, request} = request(item, principal_id(), today, Date.add(today, 7))
      assert {:ok, _} = Inventory.approve_loan(request.id, %{}, principal_id())

      assert [row] = Inventory.get_operator_loan_queue().handovers_due.rows
      assert row.id == request.id
      assert row.ready_for_checkout? == true
    end

    test "an approved loan starting tomorrow is not due yet" do
      %{item: item} = fixture()
      today = ClubCalendar.today()
      {:ok, request} = request(item, principal_id(), today, Date.add(today, 7))

      assert {:ok, _} =
               Inventory.approve_loan(
                 request.id,
                 %{"startsOn" => Date.to_iso8601(Date.add(today, 1))},
                 principal_id()
               )

      # Nothing to hand over today, so it is not the operator's next action.
      assert Inventory.get_operator_loan_queue().handovers_due.rows == []
    end

    test "an approved loan due today is still ready on its last day" do
      %{item: item} = fixture()
      today = ClubCalendar.today()
      {:ok, request} = request(item, principal_id(), today, today)
      assert {:ok, _} = Inventory.approve_loan(request.id, %{}, principal_id())

      assert [row] = Inventory.get_operator_loan_queue().handovers_due.rows
      assert row.ready_for_checkout? == true
      # The queue agrees with the command it is advertising.
      assert {:ok, _} = Inventory.check_out_loan(request.id, %{}, principal_id())
    end

    test "an approved loan whose window has lapsed stays visible but is not ready" do
      today = ClubCalendar.today()
      lapsed = lapsed_handover(today)

      assert [row] = Inventory.get_operator_loan_queue().handovers_due.rows
      assert row.id == lapsed
      # It still holds the item, so it must not vanish from the queue — but
      # checkout would refuse it, so the queue must not claim it is ready.
      assert row.ready_for_checkout? == false
      assert {:error, :outside_window} = Inventory.check_out_loan(lapsed, %{}, principal_id())
    end

    test "pushing the due date out makes a lapsed handover ready again" do
      today = ClubCalendar.today()
      lapsed = lapsed_handover(today)

      assert {:ok, _} =
               Inventory.edit_loan_dates(
                 lapsed,
                 %{"dueOn" => Date.to_iso8601(Date.add(today, 3))},
                 principal_id()
               )

      assert [row] = Inventory.get_operator_loan_queue().handovers_due.rows
      assert row.ready_for_checkout? == true
    end
  end

  describe "overdue at the club-calendar boundaries" do
    test "a loan due today is not overdue" do
      %{item: item} = fixture()
      today = ClubCalendar.today()
      {:ok, request} = request(item, principal_id(), today, today)
      assert {:ok, _} = Inventory.approve_loan(request.id, %{}, principal_id())
      assert {:ok, _} = Inventory.check_out_loan(request.id, %{}, principal_id())

      assert [row] = Inventory.get_operator_loan_queue().returns_and_overdue.rows
      assert row.overdue? == false
    end

    test "a loan due yesterday is overdue" do
      today = ClubCalendar.today()
      overdue = overdue_loan(today)

      assert [row] = Inventory.get_operator_loan_queue().returns_and_overdue.rows
      assert row.id == overdue
      assert row.overdue? == true
    end

    test "extending the due date makes an overdue loan on time again" do
      today = ClubCalendar.today()
      overdue = overdue_loan(today)

      # Overdue is derived, never stored, so there is no transition to undo.
      assert {:ok, _} =
               Inventory.edit_loan_dates(
                 overdue,
                 %{"dueOn" => Date.to_iso8601(Date.add(today, 5))},
                 principal_id()
               )

      assert [row] = Inventory.get_operator_loan_queue().returns_and_overdue.rows
      assert row.overdue? == false
    end

    test "returns and overdue share one bucket, most overdue first" do
      today = ClubCalendar.today()

      on_time = checked_out_loan()
      late = overdue_loan(today, days_late: 2)
      later = overdue_loan(today, days_late: 9)

      assert ids(Inventory.get_operator_loan_queue().returns_and_overdue) ==
               [later, late, on_time]
    end
  end

  # ── Open maintenance ────────────────────────────────────────────

  describe "open maintenance bucket" do
    test "lists an item's open period with the facts needed to act on it" do
      %{item: item} = fixture()

      assert {:ok, _} =
               Inventory.start_operator_item_maintenance(
                 item.slug,
                 %{"reason" => "Blade bent"},
                 principal_id()
               )

      assert [row] = Inventory.get_operator_loan_queue().open_maintenance.rows
      assert row.item_id == item.id
      assert row.item_slug == item.slug
      assert row.item_label != nil
      assert row.start_reason == "Blade bent"
      assert row.started_at != nil
    end

    test "ending maintenance removes the item from the bucket" do
      %{item: item} = fixture()

      assert {:ok, _} =
               Inventory.start_operator_item_maintenance(
                 item.slug,
                 %{"reason" => "Blade bent"},
                 principal_id()
               )

      assert {:ok, _} =
               Inventory.end_operator_item_maintenance(item.slug, %{}, principal_id())

      assert Inventory.get_operator_loan_queue().open_maintenance.rows == []
    end

    test "archiving a maintained item removes it from the bucket" do
      %{item: item} = fixture()

      assert {:ok, _} =
               Inventory.start_operator_item_maintenance(
                 item.slug,
                 %{"reason" => "Blade bent"},
                 principal_id()
               )

      # Archiving closes the open period atomically (ALE-294), so the queue
      # cannot keep advertising work on a retired item.
      assert {:ok, _} = Inventory.archive_operator_item(item.slug, %{}, principal_id())

      assert Inventory.get_operator_loan_queue().open_maintenance.rows == []
    end

    test "orders the longest-open period first" do
      first = maintained_item()
      second = maintained_item()

      rows = Inventory.get_operator_loan_queue().open_maintenance.rows
      assert Enum.map(rows, & &1.item_id) == [first, second]
    end
  end

  # ── Ordering ────────────────────────────────────────────────────

  describe "ordering within a bucket" do
    test "the oldest request is decided first" do
      first = requested_loan()
      second = requested_loan()
      third = requested_loan()

      assert ids(Inventory.get_operator_loan_queue().pending_requests) ==
               [first, second, third]
    end

    test "the earliest handover is due first" do
      today = ClubCalendar.today()

      later = approved_loan(starts_on: Date.add(today, -1))
      earlier = approved_loan(starts_on: Date.add(today, -4))

      assert ids(Inventory.get_operator_loan_queue().handovers_due) == [earlier, later]
    end
  end

  # ── Privacy, as its own concern ─────────────────────────────────

  describe "operator-only projection" do
    test "queue rows name the borrower and disclose the container path" do
      root = create_container!()

      {:ok, shelf} =
        Inventory.create_container(
          %{"name" => "Rack 2", "parent_container_id" => root.id},
          principal_id()
        )

      {:ok, item} = create_operator_item(shelf.id, create_category!().id)
      borrower = principal_id()
      {:ok, request} = request(item, borrower)
      assert {:ok, _} = Inventory.approve_loan(request.id, %{}, principal_id())

      assert [row] = Inventory.get_operator_loan_queue().handovers_due.rows
      # Operator-only by design: the queue is where a duty officer learns who
      # holds what and where it lives.
      assert row.borrower_principal_id == borrower
      assert row.container_path == "#{root.name} › Rack 2"
    end

    test "the member's own read model cannot express what a queue row carries" do
      %{item: item} = fixture()
      borrower = principal_id()
      {:ok, request} = request(item, borrower)
      assert {:ok, _} = Inventory.approve_loan(request.id, %{}, principal_id())

      assert [operator_row] = Inventory.get_operator_loan_queue().handovers_due.rows
      assert {:ok, member_row} = Inventory.get_own_loan(request.id, borrower)

      # The member read model is a separate read model, not a role variant:
      # borrower identity is a key it does not have at all (ALE-285).
      assert Map.has_key?(operator_row, :borrower_principal_id)
      refute Map.has_key?(member_row, :borrower_principal_id)
      refute Map.has_key?(member_row, :decided_by_principal_id)
      refute Map.has_key?(member_row, :ready_for_checkout?)
    end

    test "the member catalog cannot express the maintenance facts the queue carries" do
      %{item: item} = fixture()

      assert {:ok, _} =
               Inventory.start_operator_item_maintenance(
                 item.slug,
                 %{"reason" => "Blade bent"},
                 principal_id()
               )

      assert [operator_row] = Inventory.get_operator_loan_queue().open_maintenance.rows
      assert operator_row.start_reason == "Blade bent"

      assert {:ok, catalog_row} = Inventory.resolve_catalog_item(item.slug)

      # The member catalog is a separate read model, not a role variant: it has
      # no key for a reason, a start time, or the operator who recorded it, so
      # an operator note cannot leak by being forgotten in a filter. The member
      # sees only a generic unavailability reason (story 45).
      for operator_only <- [:start_reason, :started_at, :started_by_principal_id, :container] do
        refute Map.has_key?(catalog_row, operator_only)
      end

      assert catalog_row.availability == %{available?: false, reason: :maintenance}
    end

    test "the queue and the operator detail read agree about one loan" do
      %{item: item} = fixture()
      {:ok, request} = request(item, principal_id())
      assert {:ok, _} = Inventory.approve_loan(request.id, %{}, principal_id())

      assert [row] = Inventory.get_operator_loan_queue().handovers_due.rows
      assert {:ok, detail} = Inventory.get_operator_loan(request.id)

      # Both go through the one operator projection, so a queue row and a
      # detail read can never disagree about status, overdue, or dates.
      assert Map.delete(row, :ready_for_checkout?) == detail
    end

    test "the queue is shared: it does not depend on who is asking" do
      requested_loan()
      approved_loan()

      # No actor parameter and no claim semantics (story 50): every duty
      # officer sees the same thing.
      assert Inventory.get_operator_loan_queue() == Inventory.get_operator_loan_queue()
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────

  defp buckets(queue) do
    [
      queue.pending_requests,
      queue.handovers_due,
      queue.returns_and_overdue,
      queue.open_maintenance
    ]
  end

  defp ids(bucket), do: Enum.map(bucket.rows, & &1.id)

  defp every_loan_id(queue) do
    ids(queue.pending_requests) ++
      ids(queue.handovers_due) ++ ids(queue.returns_and_overdue)
  end

  # ── Lifecycle fixtures ──────────────────────────────────────────

  defp requested_loan do
    %{item: item} = fixture()
    {:ok, request} = request(item, principal_id())
    request.id
  end

  defp approved_loan(opts \\ []) do
    %{item: item} = fixture()
    {:ok, request} = request(item, principal_id())

    attrs =
      case Keyword.get(opts, :starts_on) do
        nil ->
          %{}

        starts_on ->
          %{
            "startsOn" => Date.to_iso8601(starts_on),
            "dueOn" => Date.to_iso8601(Date.add(starts_on, 14))
          }
      end

    assert {:ok, _} = Inventory.approve_loan(request.id, attrs, principal_id())
    request.id
  end

  # An approved loan whose whole window is in the past: never handed over, so
  # it still holds the item while checkout refuses it. Reached through the
  # real command — approval deliberately accepts a past window, because by
  # decision time the requested dates can legitimately have passed (ALE-296).
  defp lapsed_handover(today) do
    %{item: item} = fixture()
    {:ok, request} = request(item, principal_id())

    assert {:ok, _} =
             Inventory.approve_loan(
               request.id,
               %{
                 "startsOn" => Date.to_iso8601(Date.add(today, -10)),
                 "dueOn" => Date.to_iso8601(Date.add(today, -3))
               },
               principal_id()
             )

    request.id
  end

  defp checked_out_loan do
    %{item: item} = fixture()
    {:ok, request} = request(item, principal_id())
    assert {:ok, _} = Inventory.approve_loan(request.id, %{}, principal_id())
    assert {:ok, _} = Inventory.check_out_loan(request.id, %{}, principal_id())
    request.id
  end

  defp overdue_loan(today, opts \\ []) do
    days_late = Keyword.get(opts, :days_late, 1)
    id = checked_out_loan()
    set_approved_dates!(id, Date.add(today, -days_late - 7), Date.add(today, -days_late))
    id
  end

  defp closed_loan(close) do
    %{item: item} = fixture()
    {:ok, request} = request(item, principal_id())
    assert {:ok, _} = close.(request.id)
    request.id
  end

  defp maintained_item do
    %{item: item} = fixture()

    assert {:ok, _} =
             Inventory.start_operator_item_maintenance(
               item.slug,
               %{"reason" => "Awaiting parts"},
               principal_id()
             )

    item.id
  end

  # Ages an already checked-out loan past its due date. This is the one state
  # no public command can reach: checkout is gated to the approved window, and
  # `edit_loan_dates/3` refuses a due date before the handover day, so an
  # overdue loan can only be produced by the passage of time. Every other
  # fixture here goes through the real commands.
  defp set_approved_dates!(loan_id, starts_on, due_on) do
    Repo.query!(
      "UPDATE inventory_loans SET approved_start_on = $1, approved_due_on = $2 WHERE id = $3",
      [starts_on, due_on, Ecto.UUID.dump!(loan_id)]
    )
  end

  # ── Base fixtures ───────────────────────────────────────────────

  defp fixture do
    category = create_category!()
    container = create_container!()
    {:ok, item} = create_operator_item(container.id, category.id)

    %{category: category, container_id: container.id, item: item}
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

  defp create_category! do
    {:ok, category} =
      Inventory.create_category(%{
        "name" => "Loan queue category #{System.unique_integer([:positive])}"
      })

    category
  end

  defp create_container! do
    {:ok, container} =
      Inventory.create_container(
        %{"name" => "Loan queue container #{System.unique_integer([:positive])}"},
        principal_id()
      )

    container
  end

  defp principal_id do
    %Principal{id: Ecto.UUID.generate()}
    |> Principal.email_changeset(%{
      email: "loan-queue-#{System.unique_integer([:positive])}@example.com"
    })
    |> Repo.insert!()
    |> Map.fetch!(:id)
  end
end
