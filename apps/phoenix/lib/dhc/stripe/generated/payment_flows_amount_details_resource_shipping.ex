defmodule Dhc.Stripe.PaymentFlowsAmountDetailsResourceShipping do
  @moduledoc """
  Provides struct and type for a PaymentFlowsAmountDetailsResourceShipping
  """

  @type t :: %__MODULE__{
          amount: integer | nil,
          from_postal_code: String.t() | nil,
          to_postal_code: String.t() | nil
        }

  defstruct [:amount, :from_postal_code, :to_postal_code]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [amount: :integer, from_postal_code: :string, to_postal_code: :string]
  end
end
