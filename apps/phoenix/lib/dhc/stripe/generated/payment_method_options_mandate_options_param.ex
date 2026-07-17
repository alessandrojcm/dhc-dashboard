defmodule Dhc.Stripe.PaymentMethodOptionsMandateOptionsParam do
  @moduledoc """
  Provides struct and types for a PaymentMethodOptionsMandateOptionsParam
  """

  @type t :: %__MODULE__{
          amount: integer | nil,
          amount_includes_iof: String.t() | nil,
          amount_type: String.t() | nil,
          currency: String.t() | nil,
          description: String.t() | nil,
          end_date: integer | String.t() | nil,
          payment_schedule: String.t() | nil,
          reference: String.t() | nil,
          reference_prefix: String.t() | nil,
          start_date: String.t() | nil
        }

  defstruct [
    :amount,
    :amount_includes_iof,
    :amount_type,
    :currency,
    :description,
    :end_date,
    :payment_schedule,
    :reference,
    :reference_prefix,
    :start_date
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      amount_includes_iof: {:enum, ["always", "never"]},
      amount_type: {:enum, ["fixed", "maximum"]},
      currency: {:string, "currency"},
      description: :string,
      end_date: {:union, [:string, integer: "unix-time"]},
      payment_schedule: {:enum, ["halfyearly", "monthly", "quarterly", "weekly", "yearly"]},
      reference: :string,
      reference_prefix: {:union, [:string, const: ""]},
      start_date: :string
    ]
  end
end
