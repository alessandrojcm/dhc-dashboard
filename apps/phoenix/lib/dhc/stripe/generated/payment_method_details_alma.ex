defmodule Dhc.Stripe.PaymentMethodDetailsAlma do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsAlma
  """

  @type t :: %__MODULE__{
          installments: Dhc.Stripe.AlmaInstallments.t() | nil,
          transaction_id: String.t() | nil
        }

  defstruct [:installments, :transaction_id]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [installments: {Dhc.Stripe.AlmaInstallments, :t}, transaction_id: :string]
  end
end
