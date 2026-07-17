defmodule Dhc.Stripe.CustomFieldTextParam do
  @moduledoc """
  Provides struct and type for a CustomFieldTextParam
  """

  @type t :: %__MODULE__{
          default_value: String.t() | nil,
          maximum_length: integer | nil,
          minimum_length: integer | nil
        }

  defstruct [:default_value, :maximum_length, :minimum_length]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [default_value: :string, maximum_length: :integer, minimum_length: :integer]
  end
end
