defmodule Dhc.Stripe.PortalSubscriptionCancel do
  @moduledoc """
  Provides struct and type for a PortalSubscriptionCancel
  """

  @type t :: %__MODULE__{
          cancellation_reason: Dhc.Stripe.PortalSubscriptionCancellationReason.t(),
          enabled: boolean,
          mode: String.t(),
          proration_behavior: String.t()
        }

  defstruct [:cancellation_reason, :enabled, :mode, :proration_behavior]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      cancellation_reason: {Dhc.Stripe.PortalSubscriptionCancellationReason, :t},
      enabled: :boolean,
      mode: {:enum, ["at_period_end", "immediately"]},
      proration_behavior: {:enum, ["always_invoice", "create_prorations", "none"]}
    ]
  end
end
