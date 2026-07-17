defmodule Dhc.Stripe.PaymentIntentPaymentMethodOptionsCard do
  @moduledoc """
  Provides struct and type for a PaymentIntentPaymentMethodOptionsCard
  """

  @type t :: %__MODULE__{
          capture_method: String.t() | nil,
          installments: Dhc.Stripe.PaymentMethodOptionsCardInstallments.t() | nil,
          mandate_options: Dhc.Stripe.PaymentMethodOptionsCardMandateOptions.t() | nil,
          network: String.t() | nil,
          request_extended_authorization: String.t() | nil,
          request_incremental_authorization: String.t() | nil,
          request_multicapture: String.t() | nil,
          request_overcapture: String.t() | nil,
          request_three_d_secure: String.t() | nil,
          require_cvc_recollection: boolean | nil,
          setup_future_usage: String.t() | nil,
          statement_descriptor_suffix_kana: String.t() | nil,
          statement_descriptor_suffix_kanji: String.t() | nil
        }

  defstruct [
    :capture_method,
    :installments,
    :mandate_options,
    :network,
    :request_extended_authorization,
    :request_incremental_authorization,
    :request_multicapture,
    :request_overcapture,
    :request_three_d_secure,
    :require_cvc_recollection,
    :setup_future_usage,
    :statement_descriptor_suffix_kana,
    :statement_descriptor_suffix_kanji
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      capture_method: {:const, "manual"},
      installments: {Dhc.Stripe.PaymentMethodOptionsCardInstallments, :t},
      mandate_options: {Dhc.Stripe.PaymentMethodOptionsCardMandateOptions, :t},
      network:
        {:enum,
         [
           "amex",
           "cartes_bancaires",
           "diners",
           "discover",
           "eftpos_au",
           "girocard",
           "interac",
           "jcb",
           "link",
           "mastercard",
           "unionpay",
           "unknown",
           "visa"
         ]},
      request_extended_authorization: {:enum, ["if_available", "never"]},
      request_incremental_authorization: {:enum, ["if_available", "never"]},
      request_multicapture: {:enum, ["if_available", "never"]},
      request_overcapture: {:enum, ["if_available", "never"]},
      request_three_d_secure: {:enum, ["any", "automatic", "challenge"]},
      require_cvc_recollection: :boolean,
      setup_future_usage: {:enum, ["none", "off_session", "on_session"]},
      statement_descriptor_suffix_kana: :string,
      statement_descriptor_suffix_kanji: :string
    ]
  end
end
