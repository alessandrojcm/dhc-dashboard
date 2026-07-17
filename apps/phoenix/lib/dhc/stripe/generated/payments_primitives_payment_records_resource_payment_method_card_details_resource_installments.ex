defmodule Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodCardDetailsResourceInstallments do
  @moduledoc """
  Provides struct and type for a PaymentsPrimitivesPaymentRecordsResourcePaymentMethodCardDetailsResourceInstallments
  """

  @type t :: %__MODULE__{
          plan:
            Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodCardDetailsResourceInstallmentPlan.t()
            | nil
        }

  defstruct [:plan]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      plan:
        {Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodCardDetailsResourceInstallmentPlan,
         :t}
    ]
  end
end
