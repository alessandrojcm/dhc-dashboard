defmodule Dhc.Stripe.PaymentFlowsInstallmentOptions do
  @moduledoc """
  Provides struct and type for a PaymentFlowsInstallmentOptions
  """

  @type t :: %__MODULE__{
          enabled: boolean,
          plan: Dhc.Stripe.PaymentMethodDetailsCardInstallmentsPlan.t() | nil
        }

  defstruct [:enabled, :plan]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [enabled: :boolean, plan: {Dhc.Stripe.PaymentMethodDetailsCardInstallmentsPlan, :t}]
  end
end
