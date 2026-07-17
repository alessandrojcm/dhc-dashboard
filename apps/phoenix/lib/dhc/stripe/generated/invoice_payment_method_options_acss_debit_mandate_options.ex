defmodule Dhc.Stripe.InvoicePaymentMethodOptionsAcssDebitMandateOptions do
  @moduledoc """
  Provides struct and type for a InvoicePaymentMethodOptionsAcssDebitMandateOptions
  """

  @type t :: %__MODULE__{transaction_type: String.t() | nil}

  defstruct [:transaction_type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [transaction_type: {:enum, ["business", "personal"]}]
  end
end
