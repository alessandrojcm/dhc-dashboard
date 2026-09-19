defmodule Dhc.Inventory.LoanReminder do
  @moduledoc """
  Ecto schema for `inventory_loan_reminders` (ALE-282 expand).

  Durable reminder ledger keyed by
  `(loan_id, recipient_principal_id, kind, due_on_revision)` — a due-date
  change advances the revision so retry cannot emit a stale reminder.

  ALE-287 owns the scheduling over these rows
  (`Dhc.Inventory.LoanReminders`). Two fields carry the crash-safety:

    * `kind` — the occurrence, not the message: `pre_due`, `overdue`, then
      `overdue_week_<n>`. The week number is part of the kind because the
      unique key would otherwise collapse every weekly repeat onto one row.
    * `due_on_revision` — **derived from the loan's `approved_due_on`**, never
      incremented by a transition. A due-date edit therefore invalidates every
      stale key with no write on the transition path at all, which is what lets
      `Dhc.Inventory.OperatorLoans` stay reminder-free.

  `delivered_at` is stamped only once the notification exists, so an
  undelivered row is a claim awaiting repair rather than a lost reminder.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "inventory_loan_reminders" do
    field :loan_id, :binary_id
    field :recipient_principal_id, :binary_id
    field :kind, :string
    field :due_on_revision, :integer, default: 0
    field :scheduled_for, :utc_datetime_usec
    field :delivered_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end
end
