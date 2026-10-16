defmodule Dhc.BeginnersWorkshops.Commands.NotificationCopy do
  @moduledoc """
  The text of every Beginners' Workshop Notification (ALE-425): the
  coordinator alerts (`Commands.CoordinatorAlerts`, sent by
  `Commands.Batches` and `Commands.Refunds`) and the Staff Notifications
  (`Commands.Staff`, `Commands.Schedule`). Staff read these in the
  notification bell and as Web Push, so they use the copy vocabulary
  ("offer round", "places", "workshop credit", "Manage"), never a backend
  term; `beginners_workshop_copy_test.exs` renders every function here with
  fixture values against `tools/oxlint/anti-slop/shared/backend-terms.json`.

  Only the text lives here. The callers own the Notification keys, which
  deduplicate and must not change with the wording. Reach lets only
  `Commands` and `Commands.*` call this module.
  """

  alias Dhc.BeginnersWorkshops.IntakeEmails.Values

  @typedoc "What happened to a workshop credit whose refund failed, or `nil` for a payment refund."
  @type refund_follow_up :: nil | :credit_held | :credit_still_owed | :credit

  @doc false
  @spec batch_sent(Date.t(), pos_integer(), non_neg_integer()) :: String.t()
  def batch_sent(%Date{} = date, number, size) do
    "Offer round #{number} sent for the Beginners' Workshop on #{Values.date(date)}: " <>
      "#{size} #{if size == 1, do: "person", else: "people"} offered a workshop place."
  end

  @doc """
  A person paid for their workshop place through Stripe. `first_name` is
  `nil` when the person has no profile name.
  """
  @spec place_paid(String.t() | nil, Date.t()) :: String.t()
  def place_paid(first_name, %Date{} = date) do
    "#{first_name || "Someone"} paid for a place at the Beginners' Workshop on #{Values.date(date)}."
  end

  @doc false
  @spec nobody_waiting(Date.t()) :: String.t()
  def nobody_waiting(%Date{} = date) do
    "The Beginners' Workshop on #{Values.date(date)} has free places, " <>
      "but nobody is left waiting on the Waitlist."
  end

  @doc """
  An Intake Reply that could not be forwarded to the club inbox (ALE-409).
  `resend_email_id` lets the coordinator find it among Resend's received
  emails, which Resend keeps for 30 days.
  """
  @spec reply_waiting(String.t()) :: String.t()
  def reply_waiting(resend_email_id) do
    "A reply to a Beginners' Workshop email could not be forwarded to the club inbox. " <>
      "It is waiting in Resend's received emails for 30 days (email #{resend_email_id})."
  end

  @doc """
  A refund Stripe could not complete. `date` is the workshop's, when the
  refund belongs to one; `first_name` is `nil` once the person is anonymised.
  """
  @spec refund_failed(String.t(), String.t() | nil, Date.t() | nil, refund_follow_up()) ::
          String.t()
  def refund_failed(amount, first_name, date, follow_up) do
    workshop = if date, do: " for the Beginners' Workshop on #{Values.date(date)}", else: ""

    "A refund of #{amount} to #{first_name || "an anonymised person"}#{workshop} could not " <>
      "be completed. " <> refund_follow_up(follow_up)
  end

  defp refund_follow_up(nil),
    do: "Retry it or record a manual refund from the workshop's Manage page."

  defp refund_follow_up(:credit_held),
    do:
      "It was a workshop credit refund, so the person keeps their prepaid workshop place: " <>
        "retry the refund, record a manual refund or forfeit the credit from the workshop's " <>
        "Manage page or the Waitlist."

  defp refund_follow_up(:credit_still_owed),
    do:
      "It was a workshop credit refund and the person has since paid or holds another " <>
        "workshop credit, so the money is still owed back: retry it or record a manual " <>
        "refund from the workshop's Manage page or the Waitlist."

  defp refund_follow_up(:credit),
    do:
      "It was a workshop credit refund: retry it or record a manual refund from the " <>
        "workshop's Manage page or the Waitlist."

  @doc false
  @spec refund_follow_ups() :: [refund_follow_up()]
  def refund_follow_ups, do: [nil, :credit_held, :credit_still_owed, :credit]

  @doc false
  @spec staff_assigned(String.t(), map()) :: String.t()
  def staff_assigned("coach", workshop),
    do: "You're the coach for the Beginners' Workshop on #{when_where(workshop)}."

  def staff_assigned("assistant", workshop),
    do: "You're assisting at the Beginners' Workshop on #{when_where(workshop)}."

  @doc false
  @spec staff_unassigned(map()) :: String.t()
  def staff_unassigned(workshop),
    do: "You're no longer on the Staff for the Beginners' Workshop on #{when_where(workshop)}."

  @doc false
  @spec rescheduled(map()) :: String.t()
  def rescheduled(workshop),
    do: "The Beginners' Workshop you're on has moved to #{when_where(workshop)}."

  @doc false
  @spec cancelled(map()) :: String.t()
  def cancelled(workshop),
    do: "The Beginners' Workshop on #{when_where(workshop)} has been cancelled."

  defp when_where(workshop) do
    "#{Calendar.strftime(workshop.date, "%a %-d %b %Y")} at " <>
      "#{Calendar.strftime(workshop.start_time, "%H:%M")}, #{workshop.venue}"
  end
end
