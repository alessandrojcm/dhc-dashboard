defmodule Dhc.Stripe.DisputeVisaCompellingEvidence3DisputedTransaction do
  @moduledoc """
  Provides struct and type for a DisputeVisaCompellingEvidence3DisputedTransaction
  """

  @type t :: %__MODULE__{
          customer_account_id: String.t() | nil,
          customer_device_fingerprint: String.t() | nil,
          customer_device_id: String.t() | nil,
          customer_email_address: String.t() | nil,
          customer_purchase_ip: String.t() | nil,
          merchandise_or_services: String.t() | nil,
          product_description: String.t() | nil,
          shipping_address: Dhc.Stripe.DisputeTransactionShippingAddress.t() | nil
        }

  defstruct [
    :customer_account_id,
    :customer_device_fingerprint,
    :customer_device_id,
    :customer_email_address,
    :customer_purchase_ip,
    :merchandise_or_services,
    :product_description,
    :shipping_address
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      customer_account_id: :string,
      customer_device_fingerprint: :string,
      customer_device_id: :string,
      customer_email_address: :string,
      customer_purchase_ip: :string,
      merchandise_or_services: {:enum, ["merchandise", "services"]},
      product_description: :string,
      shipping_address: {Dhc.Stripe.DisputeTransactionShippingAddress, :t}
    ]
  end
end
