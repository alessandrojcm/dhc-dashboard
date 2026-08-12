defmodule Dhc.Stripe.PaymentIntentPaymentMethodOptionsParam do
  @moduledoc """
  Provides struct and types for a PaymentIntentPaymentMethodOptionsParam
  """

  @type t :: %__MODULE__{
          bank_transfer: Dhc.Stripe.BankTransferParam.t() | nil,
          capture_method: String.t() | nil,
          code: String.t() | nil,
          financial_connections: Dhc.Stripe.LinkedAccountOptionsParam.t() | nil,
          funding_type: String.t() | nil,
          mandate_options:
            Dhc.Stripe.MandateOptionsParam.t()
            | Dhc.Stripe.PaymentIntentPaymentMethodOptionsMandateOptionsParam.t()
            | Dhc.Stripe.PaymentMethodOptionsMandateOptionsParam.t()
            | nil,
          networks: Dhc.Stripe.NetworksOptionsParam.t() | nil,
          reference: String.t() | nil,
          setup_future_usage: String.t() | nil,
          target_date: String.t() | nil,
          transaction_purpose: String.t() | nil,
          verification_method: String.t() | nil
        }

  defstruct [
    :bank_transfer,
    :capture_method,
    :code,
    :financial_connections,
    :funding_type,
    :mandate_options,
    :networks,
    :reference,
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
      bank_transfer: {Dhc.Stripe.BankTransferParam, :t},
      capture_method: {:enum, ["", "manual"]},
      code: :string,
      financial_connections: {Dhc.Stripe.LinkedAccountOptionsParam, :t},
      funding_type: {:const, "bank_transfer"},
      mandate_options:
        {:union,
         [
           {Dhc.Stripe.MandateOptionsParam, :t},
           {Dhc.Stripe.PaymentIntentPaymentMethodOptionsMandateOptionsParam, :t},
           {Dhc.Stripe.PaymentMethodOptionsMandateOptionsParam, :t}
         ]},
      networks: {Dhc.Stripe.NetworksOptionsParam, :t},
      reference: {:union, [:string, const: ""]},
      setup_future_usage:
        {:enum,
         [
           "",
           "",
           "",
           "",
           "",
           "",
           "",
           "",
           "",
           "",
           "",
           "",
           "",
           "",
           "",
           "",
           "",
           "",
           "",
           "",
           "",
           "",
           "",
           "none",
           "none",
           "none",
           "none",
           "none",
           "none",
           "none",
           "none",
           "none",
           "none",
           "none",
           "none",
           "none",
           "none",
           "none",
           "none",
           "none",
           "none",
           "none",
           "none",
           "none",
           "none",
           "none",
           "none",
           "none",
           "none",
           "none",
           "none",
           "none",
           "none",
           "none",
           "none",
           "off_session",
           "off_session",
           "off_session",
           "off_session",
           "off_session",
           "off_session",
           "off_session",
           "off_session",
           "off_session",
           "off_session",
           "off_session",
           "off_session",
           "off_session",
           "off_session",
           "off_session",
           "off_session",
           "off_session",
           "off_session",
           "off_session",
           "off_session",
           "on_session",
           "on_session",
           "on_session",
           "on_session",
           "on_session",
           "on_session",
           "on_session",
           "on_session",
           "on_session",
           "on_session",
           "on_session",
           "on_session",
           "on_session",
           "on_session"
         ]},
      target_date: :string,
      transaction_purpose: {:enum, ["", "goods", "other", "services", "unspecified"]},
      verification_method: {:enum, ["automatic", "instant", "microdeposits"]}
    ]
  end
end
