defmodule Dhc.Stripe.AutomaticTaxConfig do
  @moduledoc """
  Provides struct and types for a AutomaticTaxConfig
  """

  @type t :: %__MODULE__{enabled: boolean, liability: Dhc.Stripe.Param.t() | nil}

  defstruct [:enabled, :liability]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [enabled: :boolean, liability: {Dhc.Stripe.Param, :t}]
  end
end
