defmodule Dhc.Stripe.BillingDetails do
  @moduledoc """
  Provides struct and type for a BillingDetails
  """

  @type t :: %__MODULE__{
          address: Dhc.Stripe.Address.t() | nil,
          email: String.t() | nil,
          name: String.t() | nil,
          phone: String.t() | nil,
          tax_id: String.t() | nil
        }

  defstruct [:address, :email, :name, :phone, :tax_id]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      address: {Dhc.Stripe.Address, :t},
      email: :string,
      name: :string,
      phone: :string,
      tax_id: :string
    ]
  end
end
