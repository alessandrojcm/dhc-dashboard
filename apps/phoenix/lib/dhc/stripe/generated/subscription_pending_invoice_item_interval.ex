defmodule Dhc.Stripe.SubscriptionPendingInvoiceItemInterval do
  @moduledoc """
  Provides struct and type for a SubscriptionPendingInvoiceItemInterval
  """

  @type t :: %__MODULE__{interval: String.t(), interval_count: integer}

  defstruct [:interval, :interval_count]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [interval: {:enum, ["day", "month", "week", "year"]}, interval_count: :integer]
  end
end
