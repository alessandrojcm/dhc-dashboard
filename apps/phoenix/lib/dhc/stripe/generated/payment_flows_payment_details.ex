defmodule Dhc.Stripe.PaymentFlowsPaymentDetails do
  @moduledoc """
  Provides struct and type for a PaymentFlowsPaymentDetails
  """

  @type t :: %__MODULE__{customer_reference: String.t() | nil, order_reference: String.t() | nil}

  defstruct [:customer_reference, :order_reference]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [customer_reference: :string, order_reference: :string]
  end
end
