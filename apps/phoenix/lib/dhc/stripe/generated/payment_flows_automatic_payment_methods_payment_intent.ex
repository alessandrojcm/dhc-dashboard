defmodule Dhc.Stripe.PaymentFlowsAutomaticPaymentMethodsPaymentIntent do
  @moduledoc """
  Provides struct and type for a PaymentFlowsAutomaticPaymentMethodsPaymentIntent
  """

  @type t :: %__MODULE__{allow_redirects: String.t() | nil, enabled: boolean}

  defstruct [:allow_redirects, :enabled]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [allow_redirects: {:enum, ["always", "never"]}, enabled: :boolean]
  end
end
