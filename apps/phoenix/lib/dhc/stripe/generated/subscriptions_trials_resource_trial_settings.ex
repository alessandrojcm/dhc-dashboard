defmodule Dhc.Stripe.SubscriptionsTrialsResourceTrialSettings do
  @moduledoc """
  Provides struct and type for a SubscriptionsTrialsResourceTrialSettings
  """

  @type t :: %__MODULE__{end_behavior: Dhc.Stripe.SubscriptionsTrialsResourceEndBehavior.t()}

  defstruct [:end_behavior]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [end_behavior: {Dhc.Stripe.SubscriptionsTrialsResourceEndBehavior, :t}]
  end
end
