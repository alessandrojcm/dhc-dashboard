defmodule Dhc.BeginnersWorkshops.IntakeEmails.EmailType do
  @moduledoc """
  The closed table of Intake Email types (ALE-374 "Intake Emails", ALE-377).

  Every type has one club-wide template row, one Email Kind, a fixed button
  label for action emails, and the placeholders it can fill. A template may
  use only its own type's placeholders, so no email goes out with a blank.
  Emails never name Staff, so there is no Staff placeholder.

  | Type                      | Kind   | Button             |
  | ------------------------- | ------ | ------------------ |
  | `contact_pay`             | action | Pay for your place |
  | `contact_confirm`         | action | Confirm my place   |
  | `place_confirmed_paid`    | action | View my place      |
  | `place_confirmed_carried` | action | View my place      |
  | `pre_workshop`            | action | View my place      |
  | `rescheduled`             | action | View my place      |
  | every other type          | notice | —                  |

  Every type also has its one `label`, the name staff see for it (the
  Email templates section, the console's email log and the forwarded
  reply's banner all read it from here, the dashboard through the API), and
  a plain-language `description` of the email, the only words the Intake
  Reply classifier is told about the email a person answered.

  Placeholder maxima are the longest value each placeholder can render
  (`Dhc.BeginnersWorkshops.IntakeEmails.Values` formats them); the template
  size measure counts every placeholder at its maximum.
  """

  @type id :: String.t()
  @type kind :: :action | :notice
  @type t :: %{
          id: id(),
          kind: kind(),
          button_label: String.t() | nil,
          placeholders: [String.t()],
          label: String.t(),
          description: String.t()
        }

  @maxima %{
    "firstName" => 40,
    "date" => 27,
    "startTime" => 5,
    "venue" => 80,
    "fee" => 7,
    "windowEnd" => 34,
    "paymentCutoff" => 34,
    "refundAmount" => 7
  }

  @base ~w(firstName date startTime venue)

  @types [
    %{
      id: "contact_pay",
      kind: :action,
      button_label: "Pay for your place",
      placeholders: @base ++ ~w(fee windowEnd paymentCutoff),
      label: "Place offer: payment needed",
      description: "Contact — pay for your place"
    },
    %{
      id: "contact_confirm",
      kind: :action,
      button_label: "Confirm my place",
      placeholders: @base ++ ~w(windowEnd paymentCutoff),
      label: "Place offer: use workshop credit",
      description: "Contact — confirm your place"
    },
    %{
      id: "place_confirmed_paid",
      kind: :action,
      button_label: "View my place",
      placeholders: @base ++ ~w(fee),
      label: "Place confirmed — paid",
      description: "Place confirmed after payment"
    },
    %{
      id: "place_confirmed_carried",
      kind: :action,
      button_label: "View my place",
      placeholders: @base,
      label: "Place confirmed: credit used",
      description: "Place confirmed with a workshop fee already paid"
    },
    %{
      id: "pre_workshop",
      kind: :action,
      button_label: "View my place",
      placeholders: @base,
      label: "Pre-workshop info",
      description: "Pre-workshop information"
    },
    %{
      id: "rescheduled",
      kind: :action,
      button_label: "View my place",
      placeholders: @base ++ ~w(paymentCutoff),
      label: "Workshop rescheduled",
      description: "Workshop rescheduled"
    },
    %{
      id: "follow_up",
      kind: :notice,
      button_label: nil,
      placeholders: ~w(firstName date),
      label: "Follow-up",
      description: "Follow-up after the workshop"
    },
    %{
      id: "declined",
      kind: :notice,
      button_label: nil,
      placeholders: ~w(firstName date),
      label: "Declined",
      description: "Declined from the workshop"
    },
    %{
      id: "deferred",
      kind: :notice,
      button_label: nil,
      placeholders: ~w(firstName date),
      label: "Moved to a later workshop",
      description: "Deferred to a later workshop"
    },
    %{
      id: "cancelled_with_refund",
      kind: :notice,
      button_label: nil,
      placeholders: ~w(firstName date refundAmount),
      label: "Place cancelled: refund requested",
      description: "Workshop cancelled and refund requested"
    },
    %{
      id: "withdrawn_refunded",
      kind: :notice,
      button_label: nil,
      placeholders: ~w(firstName refundAmount),
      label: "Withdrawn — refunded",
      description: "Waitlist withdrawal with refund"
    },
    %{
      id: "withdrawn_forfeited",
      kind: :notice,
      button_label: nil,
      placeholders: ~w(firstName),
      label: "Withdrawn: payment kept",
      description: "Waitlist withdrawal"
    },
    %{
      id: "carried_fee_refunded",
      kind: :notice,
      button_label: nil,
      placeholders: ~w(firstName refundAmount),
      label: "Workshop credit: refund requested",
      description: "Workshop fee refunded"
    },
    %{
      id: "payment_refunded",
      kind: :notice,
      button_label: nil,
      placeholders: ~w(firstName date refundAmount),
      label: "Automatic refund requested",
      description: "Payment refunded"
    },
    %{
      id: "cancelled_paid",
      kind: :notice,
      button_label: nil,
      placeholders: ~w(firstName date),
      label: "Workshop cancelled — paid",
      description: "Workshop cancelled after payment"
    },
    %{
      id: "cancelled_unpaid",
      kind: :notice,
      button_label: nil,
      placeholders: ~w(firstName date),
      label: "Workshop cancelled — unpaid",
      description: "Workshop cancelled before payment"
    },
    # ALE-412: a person put back on the Waitlist from their own reply.
    %{
      id: "back_on_waitlist",
      kind: :notice,
      button_label: nil,
      placeholders: ~w(firstName),
      label: "Back on the waitlist",
      description: "Put back on the Waitlist"
    }
  ]

  @by_id Map.new(@types, &{&1.id, &1})

  @ids Enum.map(@types, & &1.id)

  @doc "Every Intake Email type, in display order (action emails first)."
  @spec all() :: [t()]
  def all, do: Enum.map(@ids, &Map.fetch!(@by_id, &1))

  @doc "Every type id."
  @spec ids() :: [id()]
  def ids, do: @ids

  @spec fetch(id()) :: {:ok, t()} | :error
  def fetch(id), do: Map.fetch(@by_id, id)

  @spec fetch!(id()) :: t()
  def fetch!(id), do: Map.fetch!(@by_id, id)

  @doc "The longest value each placeholder renders."
  @spec maxima() :: %{String.t() => pos_integer()}
  def maxima, do: @maxima

  @doc "The Email Kind (`Dhc.Email.Worker` transactional id) of a type."
  @spec email_kind(t()) :: String.t()
  def email_kind(%{kind: :action}), do: "beginnersWorkshopAction"
  def email_kind(%{kind: :notice}), do: "beginnersWorkshopNotice"
end
