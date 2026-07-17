defmodule Dhc.Stripe.SharedTaxCreateParam do
  @moduledoc """
  Provides struct and type for a SharedTaxCreateParam
  """

  @type t :: %__MODULE__{ip_address: String.t() | nil, validate_location: String.t() | nil}

  defstruct [:ip_address, :validate_location]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      ip_address: {:union, [:string, const: ""]},
      validate_location: {:enum, ["deferred", "immediately"]}
    ]
  end
end
