defmodule Dhc.Stripe.UsBankAccountNetworks do
  @moduledoc """
  Provides struct and type for a UsBankAccountNetworks
  """

  @type t :: %__MODULE__{preferred: String.t() | nil, supported: [String.t()]}

  defstruct [:preferred, :supported]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [preferred: :string, supported: [enum: ["ach", "us_domestic_wire"]]]
  end
end
