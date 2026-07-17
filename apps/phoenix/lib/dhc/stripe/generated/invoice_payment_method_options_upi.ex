defmodule Dhc.Stripe.InvoicePaymentMethodOptionsUpi do
  @moduledoc """
  Provides struct and type for a InvoicePaymentMethodOptionsUpi
  """

  @type t :: %__MODULE__{
          mandate_options: Dhc.Stripe.InvoicePaymentMethodOptionsMandateOptionsUpi.t() | nil
        }

  defstruct [:mandate_options]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [mandate_options: {Dhc.Stripe.InvoicePaymentMethodOptionsMandateOptionsUpi, :t}]
  end
end
