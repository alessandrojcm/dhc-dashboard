defmodule Dhc.Stripe.IssuingTransactionFleetTaxData do
  @moduledoc """
  Provides struct and type for a IssuingTransactionFleetTaxData
  """

  @type t :: %__MODULE__{
          local_amount_decimal: String.t() | nil,
          national_amount_decimal: String.t() | nil
        }

  defstruct [:local_amount_decimal, :national_amount_decimal]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [local_amount_decimal: {:string, "decimal"}, national_amount_decimal: {:string, "decimal"}]
  end
end
