defmodule Dhc.Stripe.FlexibleParams do
  @moduledoc """
  Provides struct and types for a FlexibleParams
  """

  @type t :: %__MODULE__{proration_discounts: String.t() | nil}

  defstruct [:proration_discounts]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [proration_discounts: {:enum, ["included", "itemized"]}]
  end
end
