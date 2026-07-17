defmodule Dhc.Stripe.CustomUnitAmount do
  @moduledoc """
  Provides struct and types for a CustomUnitAmount
  """

  @type t :: %__MODULE__{
          enabled: boolean,
          maximum: integer | nil,
          minimum: integer | nil,
          preset: integer | nil
        }

  defstruct [:enabled, :maximum, :minimum, :preset]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [enabled: :boolean, maximum: :integer, minimum: :integer, preset: :integer]
  end
end
