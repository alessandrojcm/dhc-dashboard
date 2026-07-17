defmodule Dhc.Stripe.PaymentMethodKlarna do
  @moduledoc """
  Provides struct and type for a PaymentMethodKlarna
  """

  @type t :: %__MODULE__{dob: Dhc.Stripe.PaymentFlowsPrivatePaymentMethodsKlarnaDob.t() | nil}

  defstruct [:dob]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [dob: {Dhc.Stripe.PaymentFlowsPrivatePaymentMethodsKlarnaDob, :t}]
  end
end
