defmodule Dhc.Stripe.PaymentPagesCheckoutSessionCustomerDetails do
  @moduledoc """
  Provides struct and type for a PaymentPagesCheckoutSessionCustomerDetails
  """

  @type t :: %__MODULE__{
          address: Dhc.Stripe.Address.t() | nil,
          business_name: String.t() | nil,
          email: String.t() | nil,
          individual_name: String.t() | nil,
          name: String.t() | nil,
          phone: String.t() | nil,
          tax_exempt: String.t() | nil,
          tax_ids: [Dhc.Stripe.PaymentPagesCheckoutSessionTaxId.t()] | nil
        }

  defstruct [
    :address,
    :business_name,
    :email,
    :individual_name,
    :name,
    :phone,
    :tax_exempt,
    :tax_ids
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      address: {Dhc.Stripe.Address, :t},
      business_name: :string,
      email: :string,
      individual_name: :string,
      name: :string,
      phone: :string,
      tax_exempt: {:enum, ["exempt", "none", "reverse"]},
      tax_ids: [{Dhc.Stripe.PaymentPagesCheckoutSessionTaxId, :t}]
    ]
  end
end
