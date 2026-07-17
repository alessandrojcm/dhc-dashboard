defmodule Dhc.Stripe.IssuingCardWallets do
  @moduledoc """
  Provides struct and type for a IssuingCardWallets
  """

  @type t :: %__MODULE__{
          apple_pay: Dhc.Stripe.IssuingCardApplePay.t(),
          google_pay: Dhc.Stripe.IssuingCardGooglePay.t(),
          primary_account_identifier: String.t() | nil
        }

  defstruct [:apple_pay, :google_pay, :primary_account_identifier]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      apple_pay: {Dhc.Stripe.IssuingCardApplePay, :t},
      google_pay: {Dhc.Stripe.IssuingCardGooglePay, :t},
      primary_account_identifier: :string
    ]
  end
end
