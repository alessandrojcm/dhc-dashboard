defmodule Dhc.Stripe.PaymentIntentTypeSpecificPaymentMethodOptionsClient do
  @moduledoc """
  Provides struct and type for a PaymentIntentTypeSpecificPaymentMethodOptionsClient
  """

  @type t :: %__MODULE__{
          capture_method: String.t() | nil,
          installments: Dhc.Stripe.PaymentFlowsInstallmentOptions.t() | nil,
          mandate_options:
            Dhc.Stripe.PaymentIntentPaymentMethodOptionsMandateOptionsPayto.t() | nil,
          request_incremental_authorization_support: boolean | nil,
          require_cvc_recollection: boolean | nil,
          routing: Dhc.Stripe.PaymentMethodOptionsCardPresentRouting.t() | nil,
          setup_future_usage: String.t() | nil,
          verification_method: String.t() | nil
        }

  defstruct [
    :capture_method,
    :installments,
    :mandate_options,
    :request_incremental_authorization_support,
    :require_cvc_recollection,
    :routing,
    :setup_future_usage,
    :verification_method
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      capture_method: {:enum, ["automatic_delayed", "manual", "manual_preferred"]},
      installments: {Dhc.Stripe.PaymentFlowsInstallmentOptions, :t},
      mandate_options: {Dhc.Stripe.PaymentIntentPaymentMethodOptionsMandateOptionsPayto, :t},
      request_incremental_authorization_support: :boolean,
      require_cvc_recollection: :boolean,
      routing: {Dhc.Stripe.PaymentMethodOptionsCardPresentRouting, :t},
      setup_future_usage: {:enum, ["none", "off_session", "on_session"]},
      verification_method: {:enum, ["automatic", "instant", "microdeposits"]}
    ]
  end
end
