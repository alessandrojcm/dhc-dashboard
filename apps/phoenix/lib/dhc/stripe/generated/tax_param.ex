defmodule Dhc.Stripe.TaxParam do
  @moduledoc """
  Provides struct and type for a TaxParam
  """

  @type t :: %__MODULE__{ip_address: String.t() | nil}

  defstruct [:ip_address]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [ip_address: {:union, [:string, const: ""]}]
  end
end
