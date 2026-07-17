defmodule Dhc.Stripe.SubscriptionsResourceBillingSchedulesAppliesTo do
  @moduledoc """
  Provides struct and type for a SubscriptionsResourceBillingSchedulesAppliesTo
  """

  @type t :: %__MODULE__{price: Dhc.Stripe.Price.t() | String.t() | nil, type: String.t()}

  defstruct [:price, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [price: {:union, [:string, {Dhc.Stripe.Price, :t}]}, type: {:const, "price"}]
  end
end
