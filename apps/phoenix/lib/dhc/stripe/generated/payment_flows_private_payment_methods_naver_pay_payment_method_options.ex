defmodule Dhc.Stripe.PaymentFlowsPrivatePaymentMethodsNaverPayPaymentMethodOptions do
  @moduledoc """
  Provides struct and type for a PaymentFlowsPrivatePaymentMethodsNaverPayPaymentMethodOptions
  """

  @type t :: %__MODULE__{capture_method: String.t() | nil, setup_future_usage: String.t() | nil}

  defstruct [:capture_method, :setup_future_usage]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [capture_method: {:const, "manual"}, setup_future_usage: {:enum, ["none", "off_session"]}]
  end
end
