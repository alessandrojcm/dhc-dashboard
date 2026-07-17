defmodule Dhc.Stripe.SetupIntentTypeSpecificPaymentMethodOptionsClient do
  @moduledoc """
  Provides struct and type for a SetupIntentTypeSpecificPaymentMethodOptionsClient
  """

  @type t :: %__MODULE__{
          mandate_options:
            Dhc.Stripe.SetupIntentPaymentMethodOptionsMandateOptionsPayto.t() | nil,
          verification_method: String.t() | nil
        }

  defstruct [:mandate_options, :verification_method]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      mandate_options: {Dhc.Stripe.SetupIntentPaymentMethodOptionsMandateOptionsPayto, :t},
      verification_method: {:enum, ["automatic", "instant", "microdeposits"]}
    ]
  end
end
