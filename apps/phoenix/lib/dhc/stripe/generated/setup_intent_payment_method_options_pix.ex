defmodule Dhc.Stripe.SetupIntentPaymentMethodOptionsPix do
  @moduledoc """
  Provides struct and type for a SetupIntentPaymentMethodOptionsPix
  """

  @type t :: %__MODULE__{
          mandate_options: Dhc.Stripe.PaymentMethodOptionsMandateOptionsPix.t() | nil
        }

  defstruct [:mandate_options]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [mandate_options: {Dhc.Stripe.PaymentMethodOptionsMandateOptionsPix, :t}]
  end
end
