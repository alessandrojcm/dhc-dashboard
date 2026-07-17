defmodule Dhc.Stripe.Tier do
  @moduledoc """
  Provides struct and type for a Tier
  """

  @type t :: %__MODULE__{
          flat_amount: integer | nil,
          flat_amount_decimal: String.t() | nil,
          unit_amount: integer | nil,
          unit_amount_decimal: String.t() | nil,
          up_to: integer | String.t()
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
      up_to: {:union, [:integer, const: "inf"]}
    ]
  end
end
