defmodule Dhc.Stripe.SubscriptionSchedulesResourceInvoiceItemPeriodResourcePeriodEnd do
  @moduledoc """
  Provides struct and type for a SubscriptionSchedulesResourceInvoiceItemPeriodResourcePeriodEnd
  """

  @type t :: %__MODULE__{timestamp: integer | nil, type: String.t()}

  defstruct [:timestamp, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      timestamp: {:integer, "unix-time"},
      type: {:enum, ["min_item_period_end", "phase_end", "timestamp"]}
    ]
  end
end
