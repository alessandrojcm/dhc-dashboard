defmodule Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodAmazonPayDetailsResourceFunding do
  @moduledoc """
  Provides struct and type for a PaymentsPrimitivesPaymentRecordsResourcePaymentMethodAmazonPayDetailsResourceFunding
  """

  @type t :: %__MODULE__{
          card:
            Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodAmazonPayDetailsResourceFundingResourceFundingCard.t()
            | nil,
          type: String.t() | nil
        }

  defstruct [:card, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      card:
        {Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodAmazonPayDetailsResourceFundingResourceFundingCard,
         :t},
      type: {:const, "card"}
    ]
  end
end
