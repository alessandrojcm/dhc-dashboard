defmodule Dhc.Stripe.PaymentMethodDetailsCardInstallments do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsCardInstallments
  """

  @type t :: %__MODULE__{plan: Dhc.Stripe.PaymentMethodDetailsCardInstallmentsPlan.t() | nil}

  defstruct [:plan]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [plan: {Dhc.Stripe.PaymentMethodDetailsCardInstallmentsPlan, :t}]
  end
end
