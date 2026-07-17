defmodule Dhc.Stripe.SetupIntentPaymentMethodOptionsMandateOptionsAcssDebit do
  @moduledoc """
  Provides struct and type for a SetupIntentPaymentMethodOptionsMandateOptionsAcssDebit
  """

  @type t :: %__MODULE__{
          custom_mandate_url: String.t() | nil,
          default_for: [String.t()] | nil,
          interval_description: String.t() | nil,
          payment_schedule: String.t() | nil,
          transaction_type: String.t() | nil
        }

  defstruct [
    :custom_mandate_url,
    :default_for,
    :interval_description,
    :payment_schedule,
    :transaction_type
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      custom_mandate_url: :string,
      default_for: [enum: ["invoice", "subscription"]],
      interval_description: :string,
      payment_schedule: {:enum, ["combined", "interval", "sporadic"]},
      transaction_type: {:enum, ["business", "personal"]}
    ]
  end
end
