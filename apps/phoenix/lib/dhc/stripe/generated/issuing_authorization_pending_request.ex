defmodule Dhc.Stripe.IssuingAuthorizationPendingRequest do
  @moduledoc """
  Provides struct and type for a IssuingAuthorizationPendingRequest
  """

  @type t :: %__MODULE__{
          amount: integer,
          amount_details: Dhc.Stripe.IssuingAuthorizationAmountDetails.t() | nil,
          currency: String.t(),
          is_amount_controllable: boolean,
          merchant_amount: integer,
          merchant_currency: String.t(),
          network_risk_score: integer | nil
        }

  defstruct [
    :amount,
    :amount_details,
    :currency,
    :is_amount_controllable,
    :merchant_amount,
    :merchant_currency,
    :network_risk_score
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      amount_details: {Dhc.Stripe.IssuingAuthorizationAmountDetails, :t},
      currency: {:string, "currency"},
      is_amount_controllable: :boolean,
      merchant_amount: :integer,
      merchant_currency: {:string, "currency"},
      network_risk_score: :integer
    ]
  end
end
