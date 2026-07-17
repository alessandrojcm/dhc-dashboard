defmodule Dhc.Stripe.IssuingTransactionFuelData do
  @moduledoc """
  Provides struct and type for a IssuingTransactionFuelData
  """

  @type t :: %__MODULE__{
          industry_product_code: String.t() | nil,
          quantity_decimal: String.t() | nil,
          type: String.t(),
          unit: String.t(),
          unit_cost_decimal: String.t()
        }

  defstruct [:industry_product_code, :quantity_decimal, :type, :unit, :unit_cost_decimal]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      industry_product_code: :string,
      quantity_decimal: {:string, "decimal"},
      type: :string,
      unit: :string,
      unit_cost_decimal: {:string, "decimal"}
    ]
  end
end
