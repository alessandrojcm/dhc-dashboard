defmodule Dhc.Stripe.PaymentIntentPaymentMethodOptionsUsBankAccount do
  @moduledoc """
  Provides struct and type for a PaymentIntentPaymentMethodOptionsUsBankAccount
  """

  @type t :: %__MODULE__{
          financial_connections: Dhc.Stripe.LinkedAccountOptionsCommon.t() | nil,
          mandate_options: Dhc.Stripe.PaymentMethodOptionsUsBankAccountMandateOptions.t() | nil,
          setup_future_usage: String.t() | nil,
          target_date: String.t() | nil,
          transaction_purpose: String.t() | nil,
          verification_method: String.t() | nil
        }

  defstruct [
    :financial_connections,
    :mandate_options,
    :setup_future_usage,
    :target_date,
    :transaction_purpose,
    :verification_method
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      financial_connections: {Dhc.Stripe.LinkedAccountOptionsCommon, :t},
      mandate_options: {Dhc.Stripe.PaymentMethodOptionsUsBankAccountMandateOptions, :t},
      setup_future_usage: {:enum, ["none", "off_session", "on_session"]},
      target_date: :string,
      transaction_purpose: {:enum, ["goods", "other", "services", "unspecified"]},
      verification_method: {:enum, ["automatic", "instant", "microdeposits"]}
    ]
  end
end
