defmodule Dhc.Stripe.BillingDetailsInnerParams do
  @moduledoc """
  Provides struct and types for a BillingDetailsInnerParams
  """

  @type t :: %__MODULE__{
          address: Dhc.Stripe.BillingDetailsAddress.t() | String.t() | nil,
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
      address: {:union, [{Dhc.Stripe.BillingDetailsAddress, :t}, const: ""]},
      email: {:union, [:string, const: ""]},
      name: {:union, [:string, const: ""]},
      phone: {:union, [:string, const: ""]},
      tax_id: :string
    ]
  end
end
