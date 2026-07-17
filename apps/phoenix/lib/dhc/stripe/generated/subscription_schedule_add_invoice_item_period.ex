defmodule Dhc.Stripe.SubscriptionScheduleAddInvoiceItemPeriod do
  @moduledoc """
  Provides struct and type for a SubscriptionScheduleAddInvoiceItemPeriod
  """

  @type t :: %__MODULE__{
          end: Dhc.Stripe.SubscriptionSchedulesResourceInvoiceItemPeriodResourcePeriodEnd.t(),
          start: Dhc.Stripe.SubscriptionSchedulesResourceInvoiceItemPeriodResourcePeriodStart.t()
        }

  defstruct [:end, :start]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      end: {Dhc.Stripe.SubscriptionSchedulesResourceInvoiceItemPeriodResourcePeriodEnd, :t},
      start: {Dhc.Stripe.SubscriptionSchedulesResourceInvoiceItemPeriodResourcePeriodStart, :t}
    ]
  end
end
