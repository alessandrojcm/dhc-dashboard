defmodule Dhc.Stripe.PaymentMethodDetailsPaymentRecordAlma do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsPaymentRecordAlma
  """

  @type t :: %__MODULE__{
          installments:
            Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodAlmaDetailsResourceInstallments.t()
            | nil,
          transaction_id: String.t() | nil
        }

  defstruct [:installments, :transaction_id]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      installments:
        {Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodAlmaDetailsResourceInstallments,
         :t},
      transaction_id: :string
    ]
  end
end
