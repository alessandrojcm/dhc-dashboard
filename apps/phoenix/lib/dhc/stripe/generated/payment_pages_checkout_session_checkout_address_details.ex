defmodule Dhc.Stripe.PaymentPagesCheckoutSessionCheckoutAddressDetails do
  @moduledoc """
  Provides struct and type for a PaymentPagesCheckoutSessionCheckoutAddressDetails
  """

  @type t :: %__MODULE__{address: Dhc.Stripe.Address.t(), name: String.t()}

  defstruct [:address, :name]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [address: {Dhc.Stripe.Address, :t}, name: :string]
  end
end
