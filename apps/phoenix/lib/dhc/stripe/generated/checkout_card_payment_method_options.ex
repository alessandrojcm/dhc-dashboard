defmodule Dhc.Stripe.CheckoutCardPaymentMethodOptions do
  @moduledoc """
  Provides struct and type for a CheckoutCardPaymentMethodOptions
  """

  @type t :: %__MODULE__{
          capture_method: String.t() | nil,
          installments: Dhc.Stripe.CheckoutCardInstallmentsOptions.t() | nil,
          request_extended_authorization: String.t() | nil,
          request_incremental_authorization: String.t() | nil,
          request_multicapture: String.t() | nil,
          request_overcapture: String.t() | nil,
          request_three_d_secure: String.t(),
          restrictions:
            Dhc.Stripe.PaymentPagesPrivateCardPaymentMethodOptionsResourceRestrictions.t() | nil,
          setup_future_usage: String.t() | nil,
          statement_descriptor_suffix_kana: String.t() | nil,
          statement_descriptor_suffix_kanji: String.t() | nil
        }

  defstruct [
    :capture_method,
    :installments,
    :request_extended_authorization,
    :request_incremental_authorization,
    :request_multicapture,
    :request_overcapture,
    :request_three_d_secure,
    :restrictions,
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
      installments: {Dhc.Stripe.CheckoutCardInstallmentsOptions, :t},
      request_extended_authorization: {:enum, ["if_available", "never"]},
      request_incremental_authorization: {:enum, ["if_available", "never"]},
      request_multicapture: {:enum, ["if_available", "never"]},
      request_overcapture: {:enum, ["if_available", "never"]},
      request_three_d_secure: {:enum, ["any", "automatic", "challenge"]},
      restrictions:
        {Dhc.Stripe.PaymentPagesPrivateCardPaymentMethodOptionsResourceRestrictions, :t},
      setup_future_usage: {:enum, ["none", "off_session", "on_session"]},
      statement_descriptor_suffix_kana: :string,
      statement_descriptor_suffix_kanji: :string
    ]
  end
end
