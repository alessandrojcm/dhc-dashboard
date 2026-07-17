defmodule Dhc.Stripe.SubscriptionPaymentMethodOptionsMandateOptionsPix do
  @moduledoc """
  Provides struct and type for a SubscriptionPaymentMethodOptionsMandateOptionsPix
  """

  @type t :: %__MODULE__{
          amount: integer | nil,
          amount_includes_iof: String.t() | nil,
          end_date: String.t() | nil,
          payment_schedule: String.t() | nil
        }

  defstruct [:amount, :amount_includes_iof, :end_date, :payment_schedule]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      amount_includes_iof: {:enum, ["always", "never"]},
      end_date: :string,
      payment_schedule: {:enum, ["halfyearly", "monthly", "quarterly", "weekly", "yearly"]}
    ]
  end
end
