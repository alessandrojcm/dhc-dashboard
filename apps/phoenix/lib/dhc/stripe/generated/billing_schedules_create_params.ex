defmodule Dhc.Stripe.BillingSchedulesCreateParams do
  @moduledoc """
  Provides struct and type for a BillingSchedulesCreateParams
  """

  @type t :: %__MODULE__{
          applies_to: [Dhc.Stripe.BillingSchedulesAppliesTo.t()] | nil,
          bill_until: Dhc.Stripe.BillingSchedulesBillUntil.t(),
          key: String.t() | nil
        }

  defstruct [:applies_to, :bill_until, :key]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      applies_to: [{Dhc.Stripe.BillingSchedulesAppliesTo, :t}],
      bill_until: {Dhc.Stripe.BillingSchedulesBillUntil, :t},
      key: :string
    ]
  end
end
