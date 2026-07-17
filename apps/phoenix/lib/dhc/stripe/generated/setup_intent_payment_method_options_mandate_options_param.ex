defmodule Dhc.Stripe.SetupIntentPaymentMethodOptionsMandateOptionsParam do
  @moduledoc """
  Provides struct and types for a SetupIntentPaymentMethodOptionsMandateOptionsParam
  """

  @type t :: %__MODULE__{
          amount: integer | String.t() | nil,
          amount_type: String.t() | nil,
          custom_mandate_url: String.t() | nil,
          default_for: [String.t()] | nil,
          end_date: String.t() | nil,
          interval_description: String.t() | nil,
          payment_schedule: String.t() | nil,
          payments_per_period: integer | String.t() | nil,
          purpose: String.t() | nil,
          start_date: String.t() | nil,
          transaction_type: String.t() | nil
        }

  defstruct [
    :amount,
    :amount_type,
    :custom_mandate_url,
    :default_for,
    :end_date,
    :interval_description,
    :payment_schedule,
    :payments_per_period,
    :purpose,
    :start_date,
    :transaction_type
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: {:union, [:integer, const: ""]},
      amount_type: {:enum, ["", "fixed", "maximum"]},
      custom_mandate_url: {:union, [:string, const: ""]},
      default_for: [enum: ["invoice", "subscription"]],
      end_date: {:union, [:string, const: ""]},
      interval_description: :string,
      payment_schedule:
        {:enum,
         [
           "",
           "adhoc",
           "annual",
           "combined",
           "daily",
           "fortnightly",
           "interval",
           "monthly",
           "quarterly",
           "semi_annual",
           "sporadic",
           "weekly"
         ]},
      payments_per_period: {:union, [:integer, const: ""]},
      purpose:
        {:enum,
         [
           "",
           "dependant_support",
           "government",
           "loan",
           "mortgage",
           "other",
           "pension",
           "personal",
           "retail",
           "salary",
           "tax",
           "utility"
         ]},
      start_date: {:union, [:string, const: ""]},
      transaction_type: {:enum, ["business", "personal"]}
    ]
  end
end
