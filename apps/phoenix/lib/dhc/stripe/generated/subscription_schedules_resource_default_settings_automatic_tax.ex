defmodule Dhc.Stripe.SubscriptionSchedulesResourceDefaultSettingsAutomaticTax do
  @moduledoc """
  Provides struct and type for a SubscriptionSchedulesResourceDefaultSettingsAutomaticTax
  """

  @type t :: %__MODULE__{
          disabled_reason: String.t() | nil,
          enabled: boolean,
          liability: Dhc.Stripe.ConnectAccountReference.t() | nil
        }

  defstruct [:disabled_reason, :enabled, :liability]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      disabled_reason: {:const, "requires_location_inputs"},
      enabled: :boolean,
      liability: {Dhc.Stripe.ConnectAccountReference, :t}
    ]
  end
end
