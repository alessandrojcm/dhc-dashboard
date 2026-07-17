defmodule Dhc.Stripe.PaymentMethodDetailsPaymentRecordMobilepay do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsPaymentRecordMobilepay
  """

  @type t :: %__MODULE__{
          card:
            Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodMobilepayDetailsResourceCard.t()
            | nil
        }

  defstruct [:card]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      card:
        {Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodMobilepayDetailsResourceCard,
         :t}
    ]
  end
end
