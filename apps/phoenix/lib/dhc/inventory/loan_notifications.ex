defmodule Dhc.Inventory.LoanNotifications do
  @moduledoc """
  ALE-298: keyed notifications for exposed operator loan transitions.

  `Dhc.Inventory.OperatorLoans` writes durable rows and emits nothing.
  This module is the post-commit attach point: the controller calls it
  *after* a command returns, never from inside the transaction that
  reserved the item.

  Stories 48–49 decide who hears what:

    * approval — borrower, with dates and container path
    * rejection — borrower
    * operator cancellation — borrower
    * due-date change — borrower, with the new due date
    * checkout, return, ordinary edits that do not move the due date,
      automatic competing-request rejection — nobody

  Keys name the logical event (`inventory:loan:<id>:<kind>`), so a
  retried command is a no-op rather than a second unread row. A
  due-date change appends the gregorian-day revision so a later
  distinct date is a new event and a restatement is not.
  """

  alias Dhc.Notifications

  @notifying_kinds ~w(approved rejected cancelled dates_changed)a

  @doc """
  Notify the borrower of a completed operator transition, at most once.
  """
  @spec notify_loan_transition(map(), atom()) ::
          {:ok, :created | :already_created} | :ok | {:error, term()}
  def notify_loan_transition(loan, kind)
      when is_map(loan) and kind in @notifying_kinds do
    Notifications.create_keyed(
      loan.borrower_principal_id,
      key(loan, kind),
      body(loan, kind)
    )
  end

  def notify_loan_transition(_loan, _silent), do: :ok

  # A later, distinct due-date change is a new logical event. The revision
  # is the date itself (same derivation as the reminder ledger), so a
  # restatement of the same due date is a no-op and a real move is not.
  defp key(loan, :dates_changed),
    do: "inventory:loan:#{loan.id}:dates_changed:#{due_revision(loan)}"

  defp key(loan, kind), do: "inventory:loan:#{loan.id}:#{kind}"

  defp due_revision(%{approved_due_on: %Date{} = due_on}), do: Date.to_gregorian_days(due_on)
  defp due_revision(_loan), do: "none"

  defp body(loan, :approved) do
    "#{label(loan)} is approved from #{date(loan.approved_start_on)} to #{date(loan.approved_due_on)}. Collect from #{path(loan)}."
  end

  defp body(loan, :rejected), do: "Your request for #{label(loan)} was rejected."

  defp body(loan, :cancelled), do: "Your loan of #{label(loan)} was cancelled."

  defp body(loan, :dates_changed),
    do: "#{label(loan)} is now due back on #{date(loan.approved_due_on)}."

  defp label(%{item_label: label}) when is_binary(label) and label != "", do: label
  defp label(_loan), do: "A borrowed item"

  defp date(%Date{} = date), do: Date.to_iso8601(date)
  defp date(_missing), do: "an unconfirmed date"

  defp path(%{container_path: path}) when is_binary(path) and path != "", do: path
  defp path(_loan), do: "the club"
end
