defmodule Dhc.Stripe.PaymentIntentPaymentMethodOptionsMandateOptionsPayto do
  @moduledoc """
  Provides struct and type for a PaymentIntentPaymentMethodOptionsMandateOptionsPayto
  """

  @type t :: %__MODULE__{
          amount: integer | nil,
          amount_type: String.t() | nil,
          end_date: String.t() | nil,
          payment_schedule: String.t() | nil,
          payments_per_period: integer | nil,
          purpose: String.t() | nil
        }

  defstruct [:amount, :amount_type, :end_date, :payment_schedule, :payments_per_period, :purpose]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      amount_type: {:enum, ["fixed", "maximum"]},
      end_date: :string,
      payment_schedule:
        {:enum,
         [
           "adhoc",
           "annual",
           "daily",
           "fortnightly",
           "monthly",
           "quarterly",
           "semi_annual",
           "weekly"
         ]},
      payments_per_period: :integer,
      purpose:
        {:enum,
         [
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
         ]}
    ]
  end
end
