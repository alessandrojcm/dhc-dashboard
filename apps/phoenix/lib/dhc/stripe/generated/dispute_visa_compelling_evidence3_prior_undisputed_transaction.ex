defmodule Dhc.Stripe.DisputeVisaCompellingEvidence3PriorUndisputedTransaction do
  @moduledoc """
  Provides struct and type for a DisputeVisaCompellingEvidence3PriorUndisputedTransaction
  """

  @type t :: %__MODULE__{
          charge: String.t(),
          customer_account_id: String.t() | nil,
          customer_device_fingerprint: String.t() | nil,
          customer_device_id: String.t() | nil,
          customer_email_address: String.t() | nil,
          customer_purchase_ip: String.t() | nil,
          product_description: String.t() | nil,
          shipping_address: Dhc.Stripe.DisputeTransactionShippingAddress.t() | nil
        }

  defstruct [
    :charge,
    :customer_account_id,
    :customer_device_fingerprint,
    :customer_device_id,
    :customer_email_address,
    :customer_purchase_ip,
    :product_description,
    :shipping_address
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      charge: :string,
      customer_account_id: :string,
      customer_device_fingerprint: :string,
      customer_device_id: :string,
      customer_email_address: :string,
      customer_purchase_ip: :string,
      product_description: :string,
      shipping_address: {Dhc.Stripe.DisputeTransactionShippingAddress, :t}
    ]
  end
end
