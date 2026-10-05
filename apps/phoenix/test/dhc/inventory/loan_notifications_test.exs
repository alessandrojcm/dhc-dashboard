defmodule Dhc.Inventory.LoanNotificationsTest do
  @moduledoc """
  ALE-298: keyed loan-transition notifications.

  The public seam is `Dhc.Inventory.notify_loan_transition/2`. It names the
  logical event and calls `Dhc.Notifications.create_keyed/3` after the
  command has committed — never from inside `OperatorLoans`, which stays
  reminder-free and notification-free.

  Stories 48–49: approval carries dates and container path; rejection and
  operator cancellation notify; a due-date change notifies; checkout,
  return, and automatic competing-request rejection do not.
  """

  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  alias Dhc.Auth.Principal
  alias Dhc.Inventory
  alias Dhc.ClubCalendar
  alias Dhc.Notifications.Notification
  alias Dhc.Notifications.Workers.KeyedCreateWorker
  alias Dhc.Repo

  describe "approval" do
    test "notifies the borrower with dates and container path, once" do
      %{loan: loan} = approved_loan()

      assert {:ok, :enqueued} = Inventory.notify_loan_transition(loan, :approved)
      assert {:ok, :enqueued} = Inventory.notify_loan_transition(loan, :approved)
      deliver_loan_notifications()

      assert [row] = Repo.all(Notification)
      assert row.principal_id == loan.borrower_principal_id
      assert row.notification_key == "inventory:loan:#{loan.id}:approved"
      assert row.body =~ loan.item_label
      assert row.body =~ Date.to_iso8601(loan.approved_start_on)
      assert row.body =~ Date.to_iso8601(loan.approved_due_on)
      assert row.body =~ loan.container_path
    end

    test "does not notify a competing request that was rejected automatically" do
      %{item: item} = fixture()
      winner = principal_id()
      loser = principal_id()

      {:ok, winning} = request(item, winner)
      {:ok, losing} = request(item, loser)
      assert {:ok, approved} = Inventory.approve_loan(winning.id, %{}, principal_id())

      assert {:ok, :enqueued} = Inventory.notify_loan_transition(approved, :approved)
      deliver_loan_notifications()
      assert {:ok, rejected} = Inventory.get_own_loan(losing.id, loser)
      assert rejected.status == "rejected"

      # Story 49: automatic competing-request rejection is silent.
      refute_receive_notification(loser)
      assert Repo.aggregate(Notification, :count) == 1
    end
  end

  describe "rejection and operator cancellation" do
    test "notifies the borrower on an operator rejection" do
      %{item: item} = fixture()
      {:ok, request} = request(item, principal_id())
      assert {:ok, rejected} = Inventory.reject_loan(request.id, %{}, principal_id())

      assert {:ok, :enqueued} = Inventory.notify_loan_transition(rejected, :rejected)
      deliver_loan_notifications()

      [row] = Repo.all(Notification)
      assert row.principal_id == rejected.borrower_principal_id
      assert row.notification_key == "inventory:loan:#{rejected.id}:rejected"
      assert row.body =~ rejected.item_label
    end

    test "notifies the borrower on an operator cancellation" do
      %{loan: loan} = approved_loan()
      assert {:ok, cancelled} = Inventory.cancel_operator_loan(loan.id, %{}, principal_id())

      assert {:ok, :enqueued} = Inventory.notify_loan_transition(cancelled, :cancelled)
      deliver_loan_notifications()

      [row] = Repo.all(Notification)
      assert row.notification_key == "inventory:loan:#{cancelled.id}:cancelled"
      assert row.body =~ cancelled.item_label
    end
  end

  describe "due-date change" do
    test "notifies the borrower with the new due date" do
      %{loan: loan} = approved_loan()
      new_due = Date.add(loan.approved_due_on, 3)

      assert {:ok, edited} =
               Inventory.edit_loan_dates(
                 loan.id,
                 %{"dueOn" => Date.to_iso8601(new_due)},
                 principal_id()
               )

      assert {:ok, :enqueued} = Inventory.notify_loan_transition(edited, :dates_changed)
      deliver_loan_notifications()

      [row] = Repo.all(Notification)
      assert row.notification_key == dates_changed_key(edited)
      assert row.body =~ Date.to_iso8601(new_due)
    end

    test "a later distinct due date is a new event, a restatement is not" do
      %{loan: loan} = approved_loan()
      first = Date.add(loan.approved_due_on, 3)
      second = Date.add(loan.approved_due_on, 5)

      assert {:ok, once} =
               Inventory.edit_loan_dates(
                 loan.id,
                 %{"dueOn" => Date.to_iso8601(first)},
                 principal_id()
               )

      assert {:ok, :enqueued} = Inventory.notify_loan_transition(once, :dates_changed)
      assert {:ok, :enqueued} = Inventory.notify_loan_transition(once, :dates_changed)
      deliver_loan_notifications()

      assert {:ok, twice} =
               Inventory.edit_loan_dates(
                 once.id,
                 %{"dueOn" => Date.to_iso8601(second)},
                 principal_id()
               )

      assert {:ok, :enqueued} = Inventory.notify_loan_transition(twice, :dates_changed)
      deliver_loan_notifications()

      keys = Repo.all(Notification) |> Enum.map(& &1.notification_key) |> Enum.sort()
      assert keys == Enum.sort([dates_changed_key(once), dates_changed_key(twice)])
    end

    test "A to B to A to B is three events" do
      %{loan: loan} = approved_loan()
      original = loan.approved_due_on
      moved = Date.add(original, 3)

      assert {:ok, to_b} =
               Inventory.edit_loan_dates(
                 loan.id,
                 %{"dueOn" => Date.to_iso8601(moved)},
                 principal_id()
               )

      assert {:ok, :enqueued} = Inventory.notify_loan_transition(to_b, :dates_changed)

      assert {:ok, to_a} =
               Inventory.edit_loan_dates(
                 to_b.id,
                 %{"dueOn" => Date.to_iso8601(original)},
                 principal_id()
               )

      assert {:ok, :enqueued} = Inventory.notify_loan_transition(to_a, :dates_changed)

      assert {:ok, to_b_again} =
               Inventory.edit_loan_dates(
                 to_a.id,
                 %{"dueOn" => Date.to_iso8601(moved)},
                 principal_id()
               )

      assert {:ok, :enqueued} = Inventory.notify_loan_transition(to_b_again, :dates_changed)
      deliver_loan_notifications()

      keys = Repo.all(Notification) |> Enum.map(& &1.notification_key)
      assert match?([_, _, _], keys)
      assert match?([_, _, _], Enum.uniq(keys))
    end
  end

  describe "operator-facing request and member cancellation" do
    test "notifies every inventory operator of a new request, not the borrower" do
      operator = grant_operator!()
      other = grant_operator!()
      %{item: item} = fixture()
      borrower = principal_id()
      {:ok, request} = request(item, borrower)

      assert {:ok, :enqueued} = Inventory.notify_loan_transition(request, :requested)
      deliver_loan_notifications()

      rows = Repo.all(Notification)
      assert Enum.sort(Enum.map(rows, & &1.principal_id)) == Enum.sort([operator, other])
      assert Enum.all?(rows, &(&1.notification_key == "inventory:loan:#{request.id}:requested"))
      refute Enum.any?(rows, &(&1.principal_id == borrower))
    end

    test "notifies every inventory operator of a member cancellation" do
      operator = grant_operator!()
      %{item: item} = fixture()
      borrower = principal_id()
      {:ok, request} = request(item, borrower)
      assert {:ok, cancelled} = Inventory.cancel_loan(request.id, %{}, borrower)

      assert {:ok, :enqueued} = Inventory.notify_loan_transition(cancelled, :member_cancelled)
      deliver_loan_notifications()

      [row] = Repo.all(Notification)
      assert row.principal_id == operator
      assert row.notification_key == "inventory:loan:#{cancelled.id}:member_cancelled"
    end

    test "does not notify an inactive inventory operator" do
      inactive = grant_operator!(active: false)
      active = grant_operator!()
      %{item: item} = fixture()
      borrower = principal_id()
      {:ok, request} = request(item, borrower)

      assert {:ok, :enqueued} = Inventory.notify_loan_transition(request, :requested)
      deliver_loan_notifications()

      rows = Repo.all(Notification)
      assert Enum.map(rows, & &1.principal_id) == [active]
      refute Enum.any?(rows, &(&1.principal_id == inactive))
    end
  end

  describe "silent transitions" do
    test "checkout and return create no notification" do
      %{loan: loan} = approved_loan()
      assert {:ok, out} = Inventory.check_out_loan(loan.id, %{}, principal_id())
      assert {:ok, returned} = Inventory.return_loan(out.id, principal_id())

      assert :ok = Inventory.notify_loan_transition(out, :checked_out)
      assert :ok = Inventory.notify_loan_transition(returned, :returned)

      assert Repo.all(Notification) == []
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────

  defp approved_loan do
    %{item: item} = fixture()
    {:ok, request} = request(item, principal_id())
    {:ok, loan} = Inventory.approve_loan(request.id, %{}, principal_id())
    %{item: item, loan: loan}
  end

  defp fixture do
    category = create_category!()

    {:ok, root} =
      Inventory.create_container(
        %{"name" => "Clubhouse #{System.unique_integer([:positive])}"},
        principal_id()
      )

    {:ok, shelf} =
      Inventory.create_container(
        %{"name" => "Rack 2", "parent_container_id" => root.id},
        principal_id()
      )

    {:ok, item} =
      Inventory.create_operator_item(
        %{"container_id" => shelf.id, "category_id" => category.id},
        principal_id()
      )

    %{category: category, item: item}
  end

  defp request(item, borrower_id) do
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

  defp create_category! do
    {:ok, category} =
      Inventory.create_category(%{
        "name" => "Notify cat #{System.unique_integer([:positive])}"
      })

    category
  end

  defp principal_id do
    %Principal{id: Ecto.UUID.generate()}
    |> Principal.email_changeset(%{
      email: "loan-notify-#{System.unique_integer([:positive])}@example.com"
    })
    |> Repo.insert!()
    |> Map.fetch!(:id)
  end

  defp dates_changed_key(loan) do
    prev =
      case loan do
        %{previous_due_on: %Date{} = due_on} -> Date.to_gregorian_days(due_on)
        _missing -> "none"
      end

    "inventory:loan:#{loan.id}:dates_changed:#{prev}:#{Date.to_gregorian_days(loan.approved_due_on)}:#{DateTime.to_unix(loan.due_edit_at, :microsecond)}"
  end

  defp grant_operator!(opts \\ []) do
    %{principal_id: id} =
      Dhc.MemberFixtures.member_fixture(%{is_active: Keyword.get(opts, :active, true)})

    Repo.insert_all("user_roles", [
      [principal_id: Ecto.UUID.dump!(id), role: "quartermaster"]
    ])

    id
  end

  defp deliver_loan_notifications do
    for job <- all_enqueued(worker: KeyedCreateWorker) do
      assert :ok = perform_job(KeyedCreateWorker, job.args)
    end
  end

  defp refute_receive_notification(principal_id) do
    refute Enum.any?(Repo.all(Notification), &(&1.principal_id == principal_id))
  end
end
