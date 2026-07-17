defmodule Dhc.Stripe.PaymentFlowsAmountDetailsClient do
  @moduledoc """
  Provides struct and type for a PaymentFlowsAmountDetailsClient
  """

  @type t :: %__MODULE__{tip: Dhc.Stripe.PaymentFlowsAmountDetailsClientResourceTip.t() | nil}

  defstruct [:tip]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [tip: {Dhc.Stripe.PaymentFlowsAmountDetailsClientResourceTip, :t}]
  end
end
