defmodule Dhc.Inventory.Workers.LoanReminderWorkerTest do
  @moduledoc """
  ALE-287: the scheduled reminder pass.

  The schedule itself is proven in `Dhc.Inventory.LoanRemindersTest`; this
  covers what the worker adds — that a tick delivers through the context seam,
  that a repeated tick is harmless (so scheduler restarts and overlapping cron
  runs cannot duplicate), and that an undeliverable reminder does not fail the
  job and strand every other loan behind a retry.
  """

  use Dhc.DataCase, async: false

  import ExUnit.CaptureLog

  alias Dhc.Auth.Principal
  alias Dhc.Inventory
  alias Dhc.Inventory.ClubCalendar
  alias Dhc.Inventory.Workers.LoanReminderWorker
  alias Dhc.Notifications.Notification
  alias Dhc.Repo

  describe "perform/1" do
    test "delivers the reminders currently owed" do
      overdue_loan()

      assert :ok = perform_job()

      assert [%Notification{} = notification] = Repo.all(Notification)
      assert notification.body =~ "overdue"
    end

    test "a second tick in an unchanged state delivers nothing new" do
      overdue_loan()

      assert :ok = perform_job()
      assert :ok = perform_job()
      assert :ok = perform_job()

      # Scheduler restarts and overlapping cron ticks are ordinary events, not
      # a duplicate-notification source (AC 1).
      assert [_only_one] = Repo.all(Notification)
    end

    test "succeeds and logs when a reminder cannot be delivered" do
      loan = overdue_loan()
      orphan_borrower(loan)

      logs = capture_log(fn -> assert :ok = perform_job() end)

      # The job succeeds deliberately: the undelivered claim stays in the ledger
      # for the next pass, whereas failing the job would re-walk every healthy
      # loan to chase one bad recipient.
      assert logs =~ "[loan-reminder-worker]"
      assert Repo.all(Notification) == []
    end

    test "does nothing when no loan is owed a reminder" do
      assert :ok = perform_job()
      assert Repo.all(Notification) == []
    end
  end

  defp perform_job, do: LoanReminderWorker.perform(%Oban.Job{args: %{}})

  # ── Fixtures ────────────────────────────────────────────────────

  defp overdue_loan do
    today = ClubCalendar.today()
    borrower = principal()
    item = item()

    {:ok, loan} =
      Inventory.request_loan(
        item.slug,
        %{"startsOn" => Date.to_iso8601(today), "dueOn" => Date.to_iso8601(today)},
        borrower
      )

    assert {:ok, _} = Inventory.approve_loan(loan.id, %{}, principal())
    assert {:ok, _} = Inventory.check_out_loan(loan.id, %{}, principal())

    Repo.query!(
      "UPDATE inventory_loans SET approved_start_on = $1, approved_due_on = $2 WHERE id = $3",
      [Date.add(today, -8), Date.add(today, -1), Ecto.UUID.dump!(loan.id)]
    )

    loan.id
  end

  defp orphan_borrower(loan) do
    Repo.query!(
      "ALTER TABLE inventory_loans DROP CONSTRAINT IF EXISTS inventory_loans_borrower_principal_id_fkey",
      []
    )

    Repo.query!("UPDATE inventory_loans SET borrower_principal_id = $1 WHERE id = $2", [
      Ecto.UUID.dump!(Ecto.UUID.generate()),
      Ecto.UUID.dump!(loan)
    ])
  end

  defp item do
    {:ok, category} = Inventory.create_category(%{"name" => "Worker cat #{unique()}"})

    {:ok, container} =
      Inventory.create_container(%{"name" => "Worker box #{unique()}"}, principal())

    {:ok, item} =
      Inventory.create_operator_item(
        %{"container_id" => container.id, "category_id" => category.id},
        principal()
      )

    item
  end

  defp principal do
    %Principal{id: Ecto.UUID.generate()}
    |> Principal.email_changeset(%{email: "reminder-worker-#{unique()}@example.com"})
    |> Repo.insert!()
    |> Map.fetch!(:id)
  end

  defp unique, do: System.unique_integer([:positive])
end
