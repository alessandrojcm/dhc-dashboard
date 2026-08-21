defmodule Dhc.Stripe.InvoiceItemPeriodEnd do
  @moduledoc """
  Provides struct and types for a InvoiceItemPeriodEnd
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
           "min_item_period_end",
           "min_item_period_end",
           "min_item_period_end",
           "phase_end",
           "timestamp",
           "timestamp",
           "timestamp"
         ]}
    ]
  end
end
