defmodule Dhc.Stripe.PaymentMethodDetailsPaymentRecordKonbini do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsPaymentRecordKonbini
  """

  @type t :: %__MODULE__{
          store:
            Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodKonbiniDetailsResourceStore.t()
            | nil
        }

  defstruct [:store]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      store:
        {Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodKonbiniDetailsResourceStore,
         :t}
    ]
  end
end
