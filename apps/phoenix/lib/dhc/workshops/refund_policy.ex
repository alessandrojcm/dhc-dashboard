defmodule Dhc.Workshops.RefundPolicy do
  @moduledoc """
  ALE-340: the pure Refund-eligibility predicates shared by the advisory
  `Dhc.Workshops.refund_eligibility/1` read and the locked Refund commands in
  `Dhc.Workshops.PaymentCommands` (ADR 0027).

  The advisory read evaluates these against unlocked rows; the commands
  evaluate them against rows re-read under the Workshop → Registration →
  Refund locks. The advisory answer can therefore be stale, but it can never
  be computed by a different rule (the `Dhc.Inventory.LoanPolicy` pattern).

  Every function is pure: `now` is a parameter and the facts are already
  loaded. A fact map carries

    * `:registration` — the `Registration`, or `nil`;
    * `:workshop` — its `Workshop` (status, start date, refund window);
    * `:refund_requested?` — whether a Refund already exists for it.
  """

  alias Dhc.Workshops.{Registration, Workshop}

  @type facts :: %{
          registration: Registration.t() | nil,
          workshop: Workshop.t() | nil,
          refund_requested?: boolean()
        }

  @type reason ::
          :registration_not_found
          | :already_refunded
          | :workshop_finished
          | :not_paid
          | :deadline_passed
          | :already_requested

  @active_statuses ~w(pending confirmed)

  @doc """
  Whether a member or coordinator may request a Refund for the Registration.

  Checks run in a fixed order so a Registration failing several rules always
  reports the same reason.
  """
  @spec requested_refund(facts(), DateTime.t()) :: :ok | {:error, reason()}
  def requested_refund(%{registration: nil}, _now), do: {:error, :registration_not_found}

  def requested_refund(%{registration: registration, workshop: workshop} = facts, now) do
    cond do
      registration.status == "refunded" -> {:error, :already_refunded}
      workshop.status == "finished" -> {:error, :workshop_finished}
      not paid?(registration) -> {:error, :not_paid}
      deadline_passed?(workshop, now) -> {:error, :deadline_passed}
      facts.refund_requested? -> {:error, :already_requested}
      true -> :ok
    end
  end

  @doc """
  Whether the club may refund the Registration because it cancelled the
  Workshop: refund deadlines and paid-status rules do not apply, only the
  one-Refund-per-Registration rule does.
  """
  @spec cancellation_refund(facts()) :: :ok | {:error, reason()}
  def cancellation_refund(%{registration: nil}), do: {:error, :registration_not_found}
  def cancellation_refund(%{refund_requested?: true}), do: {:error, :already_requested}
  def cancellation_refund(%{registration: %Registration{}}), do: :ok

  @doc "Whether Workshop cancellation owes this Registration a Refund."
  @spec owed_on_cancellation?(Registration.t()) :: boolean()
  def owed_on_cancellation?(%Registration{} = registration),
    do: active?(registration) and paid?(registration)

  @doc "Whether the Registration still holds a place (pending or confirmed)."
  @spec active?(Registration.t()) :: boolean()
  def active?(%Registration{status: status}), do: status in @active_statuses

  @doc "The Registration statuses that hold a place."
  @spec active_statuses() :: [String.t()]
  def active_statuses, do: @active_statuses

  @doc "Whether the member's own refund window has closed."
  @spec deadline_passed?(Workshop.t(), DateTime.t()) :: boolean()
  def deadline_passed?(%Workshop{refund_days: nil}, _now), do: false

  def deadline_passed?(%Workshop{start_date: start_date, refund_days: refund_days}, now) do
    deadline = DateTime.add(start_date, -refund_days, :day)
    DateTime.compare(now, deadline) == :gt
  end

  defp paid?(%Registration{amount_paid: amount}), do: is_integer(amount) and amount > 0
end
