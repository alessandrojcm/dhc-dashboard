defmodule Dhc.Stripe.Review do
  @moduledoc """
  Provides struct and type for a Review
  """

  @type t :: %__MODULE__{
          billing_zip: String.t() | nil,
          charge: Dhc.Stripe.Charge.t() | String.t() | nil,
          closed_reason: String.t() | nil,
          created: integer,
          id: String.t(),
          ip_address: String.t() | nil,
          ip_address_location: Dhc.Stripe.RadarReviewResourceLocation.t() | nil,
          livemode: boolean,
          object: String.t(),
          open: boolean,
          opened_reason: String.t(),
          payment_intent: Dhc.Stripe.PaymentIntent.t() | String.t() | nil,
          reason: String.t(),
          session: Dhc.Stripe.RadarReviewResourceSession.t() | nil
        }

  defstruct [
    :billing_zip,
    :charge,
    :closed_reason,
    :created,
    :id,
    :ip_address,
    :ip_address_location,
    :livemode,
    :object,
    :open,
    :opened_reason,
    :payment_intent,
    :reason,
    :session
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      billing_zip: :string,
      charge: {:union, [:string, {Dhc.Stripe.Charge, :t}]},
      closed_reason:
        {:enum,
         [
           "acknowledged",
           "approved",
           "canceled",
           "disputed",
           "payment_never_settled",
           "redacted",
           "refunded",
           "refunded_as_fraud"
         ]},
      created: {:integer, "unix-time"},
      id: :string,
      ip_address: :string,
      ip_address_location: {Dhc.Stripe.RadarReviewResourceLocation, :t},
      livemode: :boolean,
      object: {:const, "review"},
      open: :boolean,
      opened_reason: {:enum, ["manual", "rule"]},
      payment_intent: {:union, [:string, {Dhc.Stripe.PaymentIntent, :t}]},
      reason: :string,
      session: {Dhc.Stripe.RadarReviewResourceSession, :t}
    ]
  end
end
