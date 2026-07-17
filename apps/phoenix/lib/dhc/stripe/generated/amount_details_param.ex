defmodule Dhc.Stripe.AmountDetailsParam do
  @moduledoc """
  Provides struct and types for a AmountDetailsParam
  """

  @type t :: %__MODULE__{
          discount_amount: integer | String.t() | nil,
          enforce_arithmetic_validation: boolean | nil,
          line_items: String.t() | [map] | nil,
          shipping: Dhc.Stripe.AmountDetailsShippingParam.t() | String.t() | nil,
          tax: Dhc.Stripe.AmountDetailsTaxParam.t() | String.t() | nil
        }

  defstruct [:discount_amount, :enforce_arithmetic_validation, :line_items, :shipping, :tax]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      discount_amount: {:union, [:integer, const: ""]},
      enforce_arithmetic_validation: :boolean,
      line_items: {:union, [{:const, ""}, [:map]]},
      shipping: {:union, [{Dhc.Stripe.AmountDetailsShippingParam, :t}, const: ""]},
      tax: {:union, [{Dhc.Stripe.AmountDetailsTaxParam, :t}, const: ""]}
    ]
  end
end
