defmodule Dhc.BeginnersWorkshops.IntakeEmails.Occasion do
  @moduledoc """
  The reason an Intake is sent an Intake Email: one named constructor per
  occasion (ALE-401). Its `name` is the `occasion` the Intake Email ledger
  (`IntakeEmailLog`) stores, unique per Intake, and stays byte-for-byte the
  string earlier code wrote, because the ledger is the schedule.

  Its `kind` decides what an occasion already in the ledger means
  (`IntakeEmails.deliver/5`):

    * `:owed` — an email the schedule owes once (`pre_workshop[:n]`,
      `follow_up`): already logged, it is skipped quietly;
    * `:event` — everything a command or Stripe causes: already logged, a
      concurrent command did it, so the command rolls back with
      `:concurrent_change`.

  Pre-workshop info and "Workshop rescheduled" carry the workshop's
  `reschedule_count` (ALE-394), so a reschedule re-arms what the new
  schedule owes without touching what was sent. `pre_workshop_sql/1` is the
  same rule for queries.
  """

  @enforce_keys [:name, :kind]
  defstruct [:name, :kind]

  @type kind :: :owed | :event
  @type t :: %__MODULE__{name: String.t(), kind: kind()}

  @doc "The Batch or Fast-track Contact email."
  @spec contact() :: t()
  def contact, do: event("contact")

  @doc "A resent link (ALE-386), named by the command's history event."
  @spec resend_link(Ecto.UUID.t()) :: t()
  def resend_link(event_id), do: event("resend_link:#{event_id}")

  @doc "A rotated link (ALE-386), named by the command's history event."
  @spec rotate_link(Ecto.UUID.t()) :: t()
  def rotate_link(event_id), do: event("rotate_link:#{event_id}")

  @doc "\"Place confirmed\" at payment or confirmation."
  @spec place_confirmed() :: t()
  def place_confirmed, do: event("place_confirmed")

  @doc "Pre-workshop info owed under a workshop's `reschedule_count`."
  @spec pre_workshop(non_neg_integer()) :: t()
  def pre_workshop(0), do: owed("pre_workshop")

  def pre_workshop(count) when is_integer(count) and count > 0,
    do: owed("pre_workshop:#{count}")

  @doc """
  `pre_workshop/1` as an SQL expression over a `reschedule_count` column,
  for queries (`IntakeEmails.owing/1`). A test keeps the two in step.
  """
  defmacro pre_workshop_sql(count) do
    quote do
      fragment(
        "CASE WHEN ? = 0 THEN 'pre_workshop' ELSE 'pre_workshop:' || ? END",
        unquote(count),
        unquote(count)
      )
    end
  end

  @doc "The `count`-th reschedule's \"Workshop rescheduled\"."
  @spec rescheduled(pos_integer()) :: t()
  def rescheduled(count) when is_integer(count) and count > 0, do: event("rescheduled:#{count}")

  @doc "\"Workshop cancelled – paid/unpaid\" (ALE-395)."
  @spec cancelled() :: t()
  def cancelled, do: event("cancelled")

  @spec declined() :: t()
  def declined, do: event("declined")

  @spec deferred() :: t()
  def deferred, do: event("deferred")

  @spec cancelled_with_refund() :: t()
  def cancelled_with_refund, do: event("cancelled_with_refund")

  @doc """
  A withdrawal, logged on the withdrawn Intake itself (the console's
  `withdraw`, or the Waitlist tab's with an open Intake).

  `withdrawn/1` is the Waitlist tab's withdrawal of a person with no open
  Intake: it is logged on the Carried Fee's original Intake, which may
  already hold this occasion, so it is named by the refund or the fee.
  """
  @spec withdrawn() :: t()
  def withdrawn, do: event("withdrawn")

  @doc "See `withdrawn/0`: named by the refund (refunded) or the fee (forfeited)."
  @spec withdrawn(Ecto.UUID.t()) :: t()
  def withdrawn(refund_or_fee_id), do: event("withdrawn:#{refund_or_fee_id}")

  @spec carried_fee_refunded(Ecto.UUID.t()) :: t()
  def carried_fee_refunded(refund_id), do: event("carried_fee_refunded:#{refund_id}")

  @doc "\"Payment refunded (automatic)\", once per payment."
  @spec payment_refunded(Ecto.UUID.t()) :: t()
  def payment_refunded(payment_id), do: event("payment_refunded:#{payment_id}")

  @doc "The Follow-up after an attended workshop."
  @spec follow_up() :: t()
  def follow_up, do: owed("follow_up")

  defp event(name), do: %__MODULE__{name: name, kind: :event}
  defp owed(name), do: %__MODULE__{name: name, kind: :owed}
end
