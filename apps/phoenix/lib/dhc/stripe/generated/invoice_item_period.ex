defmodule Dhc.Stripe.InvoiceItemPeriod do
  @moduledoc """
  Provides struct and types for a InvoiceItemPeriod
  """

  @type t :: %__MODULE__{
          end: Dhc.Stripe.InvoiceItemPeriodEnd.t(),
          start: Dhc.Stripe.InvoiceItemPeriodStart.t()
        }

  defstruct [:end, :start]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [end: {Dhc.Stripe.InvoiceItemPeriodEnd, :t}, start: {Dhc.Stripe.InvoiceItemPeriodStart, :t}]
  end
end
