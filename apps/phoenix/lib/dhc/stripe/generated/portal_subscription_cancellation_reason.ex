defmodule Dhc.Stripe.PortalSubscriptionCancellationReason do
  @moduledoc """
  Provides struct and type for a PortalSubscriptionCancellationReason
  """

  @type t :: %__MODULE__{enabled: boolean, options: [String.t()]}

  defstruct [:enabled, :options]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      enabled: :boolean,
      options: [
        enum: [
          "customer_service",
          "low_quality",
          "missing_features",
          "other",
          "switched_service",
          "too_complex",
          "too_expensive",
          "unused"
        ]
      ]
    ]
  end
end
