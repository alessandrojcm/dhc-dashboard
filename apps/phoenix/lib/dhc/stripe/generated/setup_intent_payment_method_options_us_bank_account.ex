defmodule Dhc.Stripe.SetupIntentPaymentMethodOptionsUsBankAccount do
  @moduledoc """
  Provides struct and type for a SetupIntentPaymentMethodOptionsUsBankAccount
  """

  @type t :: %__MODULE__{
          financial_connections: Dhc.Stripe.LinkedAccountOptionsCommon.t() | nil,
          mandate_options: Dhc.Stripe.PaymentMethodOptionsUsBankAccountMandateOptions.t() | nil,
          verification_method: String.t() | nil
        }

  defstruct [:financial_connections, :mandate_options, :verification_method]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      financial_connections: {Dhc.Stripe.LinkedAccountOptionsCommon, :t},
      mandate_options: {Dhc.Stripe.PaymentMethodOptionsUsBankAccountMandateOptions, :t},
      verification_method: {:enum, ["automatic", "instant", "microdeposits"]}
    ]
  end
end
