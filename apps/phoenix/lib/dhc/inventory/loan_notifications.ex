defmodule Dhc.Inventory.LoanNotifications do
  @moduledoc """
  ALE-298: keyed notifications for exposed loan transitions.

  `Dhc.Inventory.AvailabilityCommands` writes durable rows and emits nothing.
  This module is the post-commit attach point: the controller calls it
  *after* a command returns, never from inside the transaction that
  reserved the item.

  Stories 48–50 decide who hears what:

    * approval — borrower, with dates and container path
    * rejection — borrower
    * operator cancellation — borrower
    * due-date change — borrower, with the new due date, only when the
      date actually moved
    * new member request — every inventory operator
    * member cancellation — every inventory operator
    * checkout, return, ordinary edits that do not move the due date,
      automatic competing-request rejection — nobody

  Overdue operator contact is owned by `Dhc.Inventory.LoanReminders`
  (same ledger discipline as the borrower reminder).

  The controller only enqueues. `Dhc.Notifications.Workers.KeyedCreateWorker`
  calls `create_keyed/3` with retries; the key makes a repeat a no-op.
  Enqueue failure is returned to the controller so it can 500 before the
  client is told the transition succeeded.

  Keys name the logical event (`inventory:loan:<id>:<kind>`), so a
  retried command is a no-op rather than a second unread row. A
  due-date change includes the previous revision, the new revision, and
  the persist stamp so A→B→A is three events and a restatement of the
  same persist is not.
  """

  alias Dhc.Auth
  alias Dhc.Notifications.Workers.KeyedCreateWorker

  @borrower_kinds ~w(approved rejected cancelled dates_changed)a
  @operator_kinds ~w(requested member_cancelled)a
  @notifying_kinds @borrower_kinds ++ @operator_kinds

  @doc """
  Principal ids that currently hold an inventory-operator role on an
  active profile.

  Delegates to `Dhc.Auth.inventory_operator_principal_ids/1` — the same
  eligibility `RequireSession` uses for `:inventory_admin_api`.
  """
  @spec inventory_operator_ids(keyword()) :: [String.t()]
  def inventory_operator_ids(opts \\ []) when is_list(opts) do
    Auth.inventory_operator_principal_ids(opts)
  end

  @doc """
  Enqueue keyed notifications for a completed loan transition.

  Returns `{:ok, :enqueued}` when a job was accepted, `:ok` when the
  kind is silent or has no recipients, and `{:error, reason}` when
  enqueue fails.
  """
  @spec notify_loan_transition(map(), atom()) ::
          {:ok, :enqueued} | :ok | {:error, term()}
  def notify_loan_transition(loan, kind)
      when is_map(loan) and kind in @notifying_kinds do
    case recipients(loan, kind) do
      [] ->
        :ok

      principal_ids ->
        enqueue(principal_ids, key(loan, kind), body(loan, kind))
    end
  end

  def notify_loan_transition(_loan, _silent), do: :ok

  defp recipients(loan, kind) when kind in @borrower_kinds,
    do: [loan.borrower_principal_id]

  # Member views deliberately omit the borrower id (story 45). Operators
  # are still listed; we only skip the borrower when the operator view
  # named them.
  defp recipients(loan, kind) when kind in @operator_kinds,
    do: inventory_operator_ids(except: Map.get(loan, :borrower_principal_id))

  defp enqueue(principal_ids, key, body) do
    case %{principal_ids: principal_ids, key: key, body: body}
         |> KeyedCreateWorker.new()
         |> Oban.insert() do
      {:ok, _job} -> {:ok, :enqueued}
      {:error, {:conflict, _job}} -> {:ok, :enqueued}
      {:error, :conflict} -> {:ok, :enqueued}
      {:error, reason} -> {:error, reason}
    end
  end

  # A later, distinct due-date change is a new logical event. The pair of
  # revisions names the transition (A→B vs B→A); the persist stamp makes a
  # second A→B after an intervening B→A a third event. A restatement of
  # the same persist keeps the same stamp, so a retried notify is a no-op.
  defp key(loan, :dates_changed) do
    "inventory:loan:#{loan.id}:dates_changed:#{due_revision(previous_due(loan))}:#{due_revision(loan)}:#{due_edit_stamp(loan)}"
  end

  defp key(loan, kind), do: "inventory:loan:#{loan.id}:#{kind}"

  defp previous_due(%{previous_due_on: %Date{} = due_on}), do: %{approved_due_on: due_on}
  defp previous_due(_loan), do: %{approved_due_on: nil}

  defp due_revision(%{approved_due_on: %Date{} = due_on}), do: Date.to_gregorian_days(due_on)
  defp due_revision(_loan), do: "none"

  defp due_edit_stamp(%{due_edit_at: %DateTime{} = at}),
    do: DateTime.to_unix(at, :microsecond)

  defp due_edit_stamp(_loan), do: "none"

  defp body(loan, :approved) do
    "#{label(loan)} is approved from #{date(loan.approved_start_on)} to #{date(loan.approved_due_on)}. Collect from #{path(loan)}."
  end

  defp body(loan, :rejected), do: "Your request for #{label(loan)} was rejected."

  defp body(loan, :cancelled), do: "Your loan of #{label(loan)} was cancelled."

  defp body(loan, :dates_changed),
    do: "#{label(loan)} is now due back on #{date(loan.approved_due_on)}."

  defp body(loan, :requested), do: "New loan request for #{label(loan)}."

  defp body(loan, :member_cancelled),
    do: "A member cancelled their loan of #{label(loan)}."

  defp label(%{item_label: label}) when is_binary(label) and label != "", do: label
  defp label(_loan), do: "A borrowed item"

  defp date(%Date{} = date), do: Date.to_iso8601(date)
  defp date(_missing), do: "an unconfirmed date"

  defp path(%{container_path: path}) when is_binary(path) and path != "", do: path
  defp path(_loan), do: "the club"
end
