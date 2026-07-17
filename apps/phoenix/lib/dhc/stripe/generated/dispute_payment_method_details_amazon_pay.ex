defmodule Dhc.Stripe.DisputePaymentMethodDetailsAmazonPay do
  @moduledoc """
  Provides struct and type for a DisputePaymentMethodDetailsAmazonPay
  """

  @type t :: %__MODULE__{dispute_type: String.t() | nil}

  defstruct [:dispute_type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [dispute_type: {:enum, ["chargeback", "claim"]}]
  end
end
