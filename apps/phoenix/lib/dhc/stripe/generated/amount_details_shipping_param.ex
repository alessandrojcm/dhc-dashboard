defmodule Dhc.Stripe.AmountDetailsShippingParam do
  @moduledoc """
  Provides struct and types for a AmountDetailsShippingParam
  """

  @type t :: %__MODULE__{
          amount: integer | String.t() | nil,
          from_postal_code: String.t() | nil,
          to_postal_code: String.t() | nil
        }

  defstruct [:amount, :from_postal_code, :to_postal_code]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: {:union, [:integer, const: ""]},
      from_postal_code: {:union, [:string, const: ""]},
      to_postal_code: {:union, [:string, const: ""]}
    ]
  end
end
