defmodule Dhc.Stripe.PaymentMethodOptionsCardInstallments do
  @moduledoc """
  Provides struct and type for a PaymentMethodOptionsCardInstallments
  """

  @type t :: %__MODULE__{
          available_plans: [Dhc.Stripe.PaymentMethodDetailsCardInstallmentsPlan.t()] | nil,
          enabled: boolean,
          plan: Dhc.Stripe.PaymentMethodDetailsCardInstallmentsPlan.t() | nil
        }

  defstruct [:available_plans, :enabled, :plan]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      available_plans: [{Dhc.Stripe.PaymentMethodDetailsCardInstallmentsPlan, :t}],
      enabled: :boolean,
      plan: {Dhc.Stripe.PaymentMethodDetailsCardInstallmentsPlan, :t}
    ]
  end
end
