defmodule Dhc.Stripe.PortalFlowsFlowSubscriptionCancel do
  @moduledoc """
  Provides struct and type for a PortalFlowsFlowSubscriptionCancel
  """

  @type t :: %__MODULE__{
          retention: Dhc.Stripe.PortalFlowsRetention.t() | nil,
          subscription: String.t()
        }

  defstruct [:retention, :subscription]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [retention: {Dhc.Stripe.PortalFlowsRetention, :t}, subscription: :string]
  end
end
