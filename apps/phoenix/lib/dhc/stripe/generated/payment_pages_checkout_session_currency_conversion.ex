defmodule Dhc.Stripe.PaymentPagesCheckoutSessionCurrencyConversion do
  @moduledoc """
  Provides struct and type for a PaymentPagesCheckoutSessionCurrencyConversion
  """

  @type t :: %__MODULE__{
          amount_subtotal: integer,
          amount_total: integer,
          fx_rate: String.t(),
          source_currency: String.t()
        }

  defstruct [:amount_subtotal, :amount_total, :fx_rate, :source_currency]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount_subtotal: :integer,
      amount_total: :integer,
      fx_rate: {:string, "decimal"},
      source_currency: :string
    ]
  end
end
