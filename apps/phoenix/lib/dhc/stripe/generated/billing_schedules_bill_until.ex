defmodule Dhc.Stripe.BillingSchedulesBillUntil do
  @moduledoc """
  Provides struct and type for a BillingSchedulesBillUntil
  """

  @type t :: %__MODULE__{
          duration: Dhc.Stripe.BillingSchedulesBillUntilDuration.t() | nil,
          timestamp: integer | nil,
          type: String.t()
        }

  defstruct [:duration, :timestamp, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      duration: {Dhc.Stripe.BillingSchedulesBillUntilDuration, :t},
      timestamp: {:integer, "unix-time"},
      type: {:enum, ["duration", "timestamp"]}
    ]
  end
end
