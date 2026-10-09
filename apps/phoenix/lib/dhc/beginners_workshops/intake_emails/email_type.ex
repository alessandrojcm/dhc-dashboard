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
          placeholders: [String.t()]
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
    {"contact_pay", :action, "Pay for your place", @base ++ ~w(fee windowEnd paymentCutoff)},
    {"contact_confirm", :action, "Confirm my place", @base ++ ~w(windowEnd paymentCutoff)},
    {"place_confirmed_paid", :action, "View my place", @base ++ ~w(fee)},
    {"place_confirmed_carried", :action, "View my place", @base},
    {"pre_workshop", :action, "View my place", @base},
    {"rescheduled", :action, "View my place", @base ++ ~w(paymentCutoff)},
    {"follow_up", :notice, nil, ~w(firstName date)},
    {"declined", :notice, nil, ~w(firstName date)},
    {"deferred", :notice, nil, ~w(firstName date)},
    {"cancelled_with_refund", :notice, nil, ~w(firstName date refundAmount)},
    {"withdrawn_refunded", :notice, nil, ~w(firstName refundAmount)},
    {"withdrawn_forfeited", :notice, nil, ~w(firstName)},
    {"carried_fee_refunded", :notice, nil, ~w(firstName refundAmount)},
    {"payment_refunded", :notice, nil, ~w(firstName date refundAmount)},
    {"cancelled_paid", :notice, nil, ~w(firstName date)},
    {"cancelled_unpaid", :notice, nil, ~w(firstName date)}
  ]

  @by_id Map.new(@types, fn {id, kind, button_label, placeholders} ->
           {id, %{id: id, kind: kind, button_label: button_label, placeholders: placeholders}}
         end)

  @ids Enum.map(@types, &elem(&1, 0))

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
