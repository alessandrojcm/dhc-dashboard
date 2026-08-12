defmodule Dhc.Stripe.TopupResourcePaymentMethodOptions do
  @moduledoc """
  Provides struct and type for a TopupResourcePaymentMethodOptions
  """

  @type t :: %__MODULE__{us_bank_account: Dhc.Stripe.TopupResourceUsBankAccount.t() | nil}

  defstruct [:us_bank_account]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [us_bank_account: {Dhc.Stripe.TopupResourceUsBankAccount, :t}]
  end
end
