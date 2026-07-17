defmodule Dhc.Stripe.PaymentPagesCheckoutSessionCustomFieldsNumeric do
  @moduledoc """
  Provides struct and type for a PaymentPagesCheckoutSessionCustomFieldsNumeric
  """

  @type t :: %__MODULE__{
          default_value: String.t() | nil,
          maximum_length: integer | nil,
          minimum_length: integer | nil,
          value: String.t() | nil
        }

  defstruct [:default_value, :maximum_length, :minimum_length, :value]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [default_value: :string, maximum_length: :integer, minimum_length: :integer, value: :string]
  end
end
