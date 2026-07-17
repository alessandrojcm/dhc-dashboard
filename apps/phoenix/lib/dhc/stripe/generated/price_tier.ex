defmodule Dhc.Stripe.PriceTier do
  @moduledoc """
  Provides struct and type for a PriceTier
  """

  @type t :: %__MODULE__{
          flat_amount: integer | nil,
          flat_amount_decimal: String.t() | nil,
          unit_amount: integer | nil,
          unit_amount_decimal: String.t() | nil,
          up_to: integer | nil
        }

  defstruct [:flat_amount, :flat_amount_decimal, :unit_amount, :unit_amount_decimal, :up_to]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      flat_amount: :integer,
      flat_amount_decimal: {:string, "decimal"},
      unit_amount: :integer,
      unit_amount_decimal: {:string, "decimal"},
      up_to: :integer
    ]
  end
end
