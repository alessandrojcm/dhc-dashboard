defmodule Dhc.Stripe.PaymentLinksResourceOptionalItemAdjustableQuantity do
  @moduledoc """
  Provides struct and type for a PaymentLinksResourceOptionalItemAdjustableQuantity
  """

  @type t :: %__MODULE__{enabled: boolean, maximum: integer | nil, minimum: integer | nil}

  defstruct [:enabled, :maximum, :minimum]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [enabled: :boolean, maximum: :integer, minimum: :integer]
  end
end
