defmodule Dhc.Stripe.InvoicesPaymentsInvoicePaymentStatusTransitions do
  @moduledoc """
  Provides struct and type for a InvoicesPaymentsInvoicePaymentStatusTransitions
  """

  @type t :: %__MODULE__{canceled_at: integer | nil, paid_at: integer | nil}

  defstruct [:canceled_at, :paid_at]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [canceled_at: {:integer, "unix-time"}, paid_at: {:integer, "unix-time"}]
  end
end
