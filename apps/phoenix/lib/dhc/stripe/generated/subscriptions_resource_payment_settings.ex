defmodule Dhc.Stripe.SubscriptionsResourcePaymentSettings do
  @moduledoc """
  Provides struct and type for a SubscriptionsResourcePaymentSettings
  """

  @type t :: %__MODULE__{
          payment_method_options: Dhc.Stripe.SubscriptionsResourcePaymentMethodOptions.t() | nil,
          payment_method_types: [String.t()] | nil,
          save_default_payment_method: String.t() | nil
        }

  defstruct [:payment_method_options, :payment_method_types, :save_default_payment_method]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      payment_method_options: {Dhc.Stripe.SubscriptionsResourcePaymentMethodOptions, :t},
      payment_method_types: [
        enum: [
          "ach_credit_transfer",
          "ach_debit",
          "acss_debit",
          "affirm",
          "amazon_pay",
          "au_becs_debit",
          "bacs_debit",
          "bancontact",
          "boleto",
          "card",
          "cashapp",
          "crypto",
          "custom",
          "customer_balance",
          "eps",
          "fpx",
          "giropay",
          "grabpay",
          "ideal",
          "jp_credit_transfer",
          "kakao_pay",
          "klarna",
          "konbini",
          "kr_card",
          "link",
          "multibanco",
          "naver_pay",
          "nz_bank_account",
          "p24",
          "pay_by_bank",
          "payco",
          "paynow",
          "paypal",
          "payto",
          "pix",
          "promptpay",
          "revolut_pay",
          "satispay",
          "sepa_credit_transfer",
          "sepa_debit",
          "sofort",
          "swish",
          "twint",
          "upi",
          "us_bank_account",
          "wechat_pay"
        ]
      ],
      save_default_payment_method: {:enum, ["off", "on_subscription"]}
    ]
  end
end
