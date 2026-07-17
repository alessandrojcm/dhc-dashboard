defmodule Dhc.Stripe.PaymentFlowsAmountDetailsClientResourceTip do
  @moduledoc """
  Provides struct and type for a PaymentFlowsAmountDetailsClientResourceTip
  """

  @type t :: %__MODULE__{amount: integer | nil}

  defstruct [:amount]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [amount: :integer]
  end
end
