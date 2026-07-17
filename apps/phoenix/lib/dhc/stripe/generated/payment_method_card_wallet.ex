defmodule Dhc.Stripe.PaymentMethodCardWallet do
  @moduledoc """
  Provides struct and type for a PaymentMethodCardWallet
  """

  @type t :: %__MODULE__{
          amex_express_checkout: map | nil,
          apple_pay: map | nil,
          dynamic_last4: String.t() | nil,
          google_pay: map | nil,
          link: map | nil,
          masterpass: Dhc.Stripe.PaymentMethodCardWalletMasterpass.t() | nil,
          samsung_pay: map | nil,
          type: String.t(),
          visa_checkout: Dhc.Stripe.PaymentMethodCardWalletVisaCheckout.t() | nil
        }

  defstruct [
    :amex_express_checkout,
    :apple_pay,
    :dynamic_last4,
    :google_pay,
    :link,
    :masterpass,
    :samsung_pay,
    :type,
    :visa_checkout
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amex_express_checkout: :map,
      apple_pay: :map,
      dynamic_last4: :string,
      google_pay: :map,
      link: :map,
      masterpass: {Dhc.Stripe.PaymentMethodCardWalletMasterpass, :t},
      samsung_pay: :map,
      type:
        {:enum,
         [
           "amex_express_checkout",
           "apple_pay",
           "google_pay",
           "link",
           "masterpass",
           "samsung_pay",
           "visa_checkout"
         ]},
      visa_checkout: {Dhc.Stripe.PaymentMethodCardWalletVisaCheckout, :t}
    ]
  end
end
