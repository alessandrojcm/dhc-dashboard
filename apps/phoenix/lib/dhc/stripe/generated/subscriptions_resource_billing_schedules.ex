defmodule Dhc.Stripe.SubscriptionsResourceBillingSchedules do
  @moduledoc """
  Provides struct and type for a SubscriptionsResourceBillingSchedules
  """

  @type t :: %__MODULE__{
          applies_to: [Dhc.Stripe.SubscriptionsResourceBillingSchedulesAppliesTo.t()] | nil,
          bill_until: Dhc.Stripe.SubscriptionsResourceBillingSchedulesBillUntil.t(),
          key: String.t()
        }

  defstruct [:applies_to, :bill_until, :key]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      applies_to: [{Dhc.Stripe.SubscriptionsResourceBillingSchedulesAppliesTo, :t}],
      bill_until: {Dhc.Stripe.SubscriptionsResourceBillingSchedulesBillUntil, :t},
      key: :string
    ]
  end
end
