defmodule Dhc.Stripe.TrialSettingsConfig do
  @moduledoc """
  Provides struct and types for a TrialSettingsConfig
  """

  @type t :: %__MODULE__{end_behavior: Dhc.Stripe.EndBehavior.t()}

  defstruct [:end_behavior]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [end_behavior: {Dhc.Stripe.EndBehavior, :t}]
  end
end
