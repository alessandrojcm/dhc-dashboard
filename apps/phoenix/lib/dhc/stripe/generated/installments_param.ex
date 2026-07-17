defmodule Dhc.Stripe.InstallmentsParam do
  @moduledoc """
  Provides struct and types for a InstallmentsParam
  """

  @type t :: %__MODULE__{
          enabled: boolean | nil,
          plan: Dhc.Stripe.InstallmentPlan.t() | String.t() | nil
        }

  defstruct [:enabled, :plan]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [enabled: :boolean, plan: {:union, [{Dhc.Stripe.InstallmentPlan, :t}, const: ""]}]
  end
end
