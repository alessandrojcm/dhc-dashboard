defmodule Dhc.Stripe.SubscriptionsResourceTrialSettingsTrialSettings do
  @moduledoc """
  Provides struct and type for a SubscriptionsResourceTrialSettingsTrialSettings
  """

  @type t :: %__MODULE__{
          end_behavior: Dhc.Stripe.SubscriptionsResourceTrialSettingsEndBehavior.t()
        }

  defstruct [:end_behavior]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [end_behavior: {Dhc.Stripe.SubscriptionsResourceTrialSettingsEndBehavior, :t}]
  end
end
