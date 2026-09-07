defmodule Dhc.Inventory.LoanReminder do
  @moduledoc """
  Ecto schema for `inventory_loan_reminders` (ALE-282 expand).

  Durable reminder ledger keyed by
  `(loan_id, recipient_principal_id, kind, due_on_revision)` — a due-date
  change advances the revision so retry cannot emit a stale reminder. Storage
  only — scheduling lands in ALE-287. Not reachable through `Dhc.Inventory`
  yet.
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
