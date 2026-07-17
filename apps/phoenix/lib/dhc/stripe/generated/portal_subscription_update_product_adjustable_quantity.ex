defmodule Dhc.Stripe.PortalSubscriptionUpdateProductAdjustableQuantity do
  @moduledoc """
  Provides struct and type for a PortalSubscriptionUpdateProductAdjustableQuantity
  """

  @type t :: %__MODULE__{enabled: boolean, maximum: integer | nil, minimum: integer}

  defstruct [:enabled, :maximum, :minimum]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [enabled: :boolean, maximum: :integer, minimum: :integer]
  end
end
