defmodule Dhc.Stripe.PaymentIntentPaymentMethodOptionsAcssDebit do
  @moduledoc """
  Provides struct and type for a PaymentIntentPaymentMethodOptionsAcssDebit
  """

  @type t :: %__MODULE__{
          mandate_options:
            Dhc.Stripe.PaymentIntentPaymentMethodOptionsMandateOptionsAcssDebit.t() | nil,
          setup_future_usage: String.t() | nil,
          target_date: String.t() | nil,
          verification_method: String.t() | nil
        }

  defstruct [:mandate_options, :setup_future_usage, :target_date, :verification_method]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      mandate_options: {Dhc.Stripe.PaymentIntentPaymentMethodOptionsMandateOptionsAcssDebit, :t},
      setup_future_usage: {:enum, ["none", "off_session", "on_session"]},
      target_date: :string,
      verification_method: {:enum, ["automatic", "instant", "microdeposits"]}
    ]
  end
end
