defmodule Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodRevolutPayDetailsResourceFunding do
  @moduledoc """
  Provides struct and type for a PaymentsPrimitivesPaymentRecordsResourcePaymentMethodRevolutPayDetailsResourceFunding
  """

  @type t :: %__MODULE__{
          card:
            Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodRevolutPayDetailsResourceFundingResourceFundingCard.t()
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
        {Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodRevolutPayDetailsResourceFundingResourceFundingCard,
         :t},
      type: {:const, "card"}
    ]
  end
end
