defmodule Dhc.Stripe.PaymentPagesCheckoutSessionCollectedInformation do
  @moduledoc """
  Provides struct and type for a PaymentPagesCheckoutSessionCollectedInformation
  """

  @type t :: %__MODULE__{
          business_name: String.t() | nil,
          individual_name: String.t() | nil,
          shipping_details: Dhc.Stripe.PaymentPagesCheckoutSessionCheckoutAddressDetails.t() | nil
        }

  defstruct [:business_name, :individual_name, :shipping_details]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      business_name: :string,
      individual_name: :string,
      shipping_details: {Dhc.Stripe.PaymentPagesCheckoutSessionCheckoutAddressDetails, :t}
    ]
  end
end
