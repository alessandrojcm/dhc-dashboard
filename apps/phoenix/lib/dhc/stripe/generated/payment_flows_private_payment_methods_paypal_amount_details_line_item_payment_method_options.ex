defmodule Dhc.Stripe.PaymentFlowsPrivatePaymentMethodsPaypalAmountDetailsLineItemPaymentMethodOptions do
  @moduledoc """
  Provides struct and type for a PaymentFlowsPrivatePaymentMethodsPaypalAmountDetailsLineItemPaymentMethodOptions
  """

  @type t :: %__MODULE__{
          category: String.t() | nil,
          description: String.t() | nil,
          sold_by: String.t() | nil
        }

  defstruct [:category, :description, :sold_by]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      category: {:enum, ["digital_goods", "donation", "physical_goods"]},
      description: :string,
      sold_by: :string
    ]
  end
end
