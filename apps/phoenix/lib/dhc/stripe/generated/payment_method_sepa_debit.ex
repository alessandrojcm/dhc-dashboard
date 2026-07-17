defmodule Dhc.Stripe.PaymentMethodSepaDebit do
  @moduledoc """
  Provides struct and type for a PaymentMethodSepaDebit
  """

  @type t :: %__MODULE__{
          bank_code: String.t() | nil,
          branch_code: String.t() | nil,
          country: String.t() | nil,
          fingerprint: String.t() | nil,
          generated_from: Dhc.Stripe.SepaDebitGeneratedFrom.t() | nil,
          last4: String.t() | nil
        }

  defstruct [:bank_code, :branch_code, :country, :fingerprint, :generated_from, :last4]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      bank_code: :string,
      branch_code: :string,
      country: :string,
      fingerprint: :string,
      generated_from: {Dhc.Stripe.SepaDebitGeneratedFrom, :t},
      last4: :string
    ]
  end
end
