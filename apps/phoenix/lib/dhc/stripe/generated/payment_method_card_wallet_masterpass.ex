defmodule Dhc.Stripe.PaymentMethodCardWalletMasterpass do
  @moduledoc """
  Provides struct and type for a PaymentMethodCardWalletMasterpass
  """

  @type t :: %__MODULE__{
          billing_address: Dhc.Stripe.Address.t() | nil,
          email: String.t() | nil,
          name: String.t() | nil,
          shipping_address: Dhc.Stripe.Address.t() | nil
        }

  defstruct [:billing_address, :email, :name, :shipping_address]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      billing_address: {Dhc.Stripe.Address, :t},
      email: :string,
      name: :string,
      shipping_address: {Dhc.Stripe.Address, :t}
    ]
  end
end
