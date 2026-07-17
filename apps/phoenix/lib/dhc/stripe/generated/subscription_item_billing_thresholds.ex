defmodule Dhc.Stripe.SubscriptionItemBillingThresholds do
  @moduledoc """
  Provides struct and type for a SubscriptionItemBillingThresholds
  """

  @type t :: %__MODULE__{usage_gte: integer | nil}

  defstruct [:usage_gte]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [usage_gte: :integer]
  end
end
