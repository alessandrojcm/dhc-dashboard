defmodule Dhc.Stripe.InvoicesPaymentSettings do
  @moduledoc """
  Provides struct and type for a InvoicesPaymentSettings
  """

  @type t :: %__MODULE__{
          default_mandate: String.t() | nil,
          payment_method_options: Dhc.Stripe.InvoicesPaymentMethodOptions.t() | nil,
          payment_method_types: [String.t()] | nil
        }

  defstruct [:default_mandate, :payment_method_options, :payment_method_types]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      default_mandate: :string,
      payment_method_options: {Dhc.Stripe.InvoicesPaymentMethodOptions, :t},
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
      ]
    ]
  end
end
