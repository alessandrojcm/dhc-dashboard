defmodule Dhc.Stripe.InvoiceItemPeriodStart do
  @moduledoc """
  Provides struct and types for a InvoiceItemPeriodStart
  """

  @type t :: %__MODULE__{timestamp: integer | nil, type: String.t()}

  defstruct [:timestamp, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      timestamp: {:integer, "unix-time"},
      type:
        {:enum,
         [
           "max_item_period_start",
           "max_item_period_start",
           "now",
           "phase_start",
           "timestamp",
           "timestamp"
         ]}
    ]
  end
end
