defmodule Dhc.Stripe.BillingMode do
  @moduledoc """
  Provides struct and types for a BillingMode
  """

  @type t :: %__MODULE__{flexible: Dhc.Stripe.FlexibleParams.t() | nil, type: String.t()}

  defstruct [:flexible, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [flexible: {Dhc.Stripe.FlexibleParams, :t}, type: {:enum, ["classic", "flexible"]}]
  end
end
