defmodule Dhc.Stripe.AccountMonthlyEstimatedRevenue do
  @moduledoc """
  Provides struct and type for a AccountMonthlyEstimatedRevenue
  """

  @type t :: %__MODULE__{amount: integer, currency: String.t()}

  defstruct [:amount, :currency]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [amount: :integer, currency: {:string, "currency"}]
  end
end
