defmodule Dhc.Stripe.ItemBillingThresholdsParam do
  @moduledoc """
  Provides struct and types for a ItemBillingThresholdsParam
  """

  @type t :: %__MODULE__{usage_gte: integer}

  defstruct [:usage_gte]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [usage_gte: :integer]
  end
end
