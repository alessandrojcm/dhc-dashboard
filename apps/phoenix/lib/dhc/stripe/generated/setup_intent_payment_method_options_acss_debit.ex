defmodule Dhc.Stripe.SetupIntentPaymentMethodOptionsAcssDebit do
  @moduledoc """
  Provides struct and type for a SetupIntentPaymentMethodOptionsAcssDebit
  """

  @type t :: %__MODULE__{
          currency: String.t() | nil,
          mandate_options:
            Dhc.Stripe.SetupIntentPaymentMethodOptionsMandateOptionsAcssDebit.t() | nil,
          verification_method: String.t() | nil
        }

  defstruct [:currency, :mandate_options, :verification_method]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      currency: {:enum, ["cad", "usd"]},
      mandate_options: {Dhc.Stripe.SetupIntentPaymentMethodOptionsMandateOptionsAcssDebit, :t},
      verification_method: {:enum, ["automatic", "instant", "microdeposits"]}
    ]
  end
end
