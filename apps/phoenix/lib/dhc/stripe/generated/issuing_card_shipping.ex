defmodule Dhc.Stripe.IssuingCardShipping do
  @moduledoc """
  Provides struct and type for a IssuingCardShipping
  """

  @type t :: %__MODULE__{
          address: Dhc.Stripe.Address.t(),
          address_validation: Dhc.Stripe.IssuingCardShippingAddressValidation.t() | nil,
          business_name: String.t() | nil,
          carrier: String.t() | nil,
          customs: Dhc.Stripe.IssuingCardShippingCustoms.t() | nil,
          eta: integer | nil,
          name: String.t(),
          phone_number: String.t() | nil,
          require_signature: boolean | nil,
          service: String.t(),
          status: String.t() | nil,
          tracking_number: String.t() | nil,
          tracking_url: String.t() | nil,
          type: String.t()
        }

  defstruct [
    :address,
    :address_validation,
    :business_name,
    :carrier,
    :customs,
    :eta,
    :name,
    :phone_number,
    :require_signature,
    :service,
    :status,
    :tracking_number,
    :tracking_url,
    :type
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      address: {Dhc.Stripe.Address, :t},
      address_validation: {Dhc.Stripe.IssuingCardShippingAddressValidation, :t},
      business_name: :string,
      carrier: {:enum, ["correos", "dhl", "fedex", "royal_mail", "usps"]},
      customs: {Dhc.Stripe.IssuingCardShippingCustoms, :t},
      eta: {:integer, "unix-time"},
      name: :string,
      phone_number: :string,
      require_signature: :boolean,
      service: {:enum, ["express", "priority", "standard"]},
      status:
        {:enum,
         ["canceled", "delivered", "failure", "pending", "returned", "shipped", "submitted"]},
      tracking_number: :string,
      tracking_url: :string,
      type: {:enum, ["bulk", "individual"]}
    ]
  end
end
