defmodule Dhc.Stripe.SourceOwner do
  @moduledoc """
  Provides struct and type for a SourceOwner
  """

  @type t :: %__MODULE__{
          address: Dhc.Stripe.Address.t() | nil,
          email: String.t() | nil,
          name: String.t() | nil,
          phone: String.t() | nil,
          verified_address: Dhc.Stripe.Address.t() | nil,
          verified_email: String.t() | nil,
          verified_name: String.t() | nil,
          verified_phone: String.t() | nil
        }

  defstruct [
    :address,
    :email,
    :name,
    :phone,
    :verified_address,
    :verified_email,
    :verified_name,
    :verified_phone
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      address: {Dhc.Stripe.Address, :t},
      email: :string,
      name: :string,
      phone: :string,
      verified_address: {Dhc.Stripe.Address, :t},
      verified_email: :string,
      verified_name: :string,
      verified_phone: :string
    ]
  end
end
