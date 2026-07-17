defmodule Dhc.Stripe.SubscriptionsResourceBillingSchedulesBillUntil do
  @moduledoc """
  Provides struct and type for a SubscriptionsResourceBillingSchedulesBillUntil
  """

  @type t :: %__MODULE__{
          computed_timestamp: integer,
          duration: Dhc.Stripe.SubscriptionsResourceBillingSchedulesBillUntilDuration.t() | nil,
          timestamp: integer | nil,
          type: String.t()
        }

  defstruct [:computed_timestamp, :duration, :timestamp, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      computed_timestamp: {:integer, "unix-time"},
      duration: {Dhc.Stripe.SubscriptionsResourceBillingSchedulesBillUntilDuration, :t},
      timestamp: {:integer, "unix-time"},
      type: {:enum, ["duration", "timestamp"]}
    ]
  end
end
