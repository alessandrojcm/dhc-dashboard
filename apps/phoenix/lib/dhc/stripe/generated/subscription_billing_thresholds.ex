defmodule Dhc.Stripe.SubscriptionBillingThresholds do
  @moduledoc """
  Provides struct and type for a SubscriptionBillingThresholds
  """

  @type t :: %__MODULE__{amount_gte: integer | nil, reset_billing_cycle_anchor: boolean | nil}

  defstruct [:amount_gte, :reset_billing_cycle_anchor]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [amount_gte: :integer, reset_billing_cycle_anchor: :boolean]
  end
end
