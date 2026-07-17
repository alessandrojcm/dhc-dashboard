defmodule Dhc.Stripe.IssuingTransactionAmountDetails do
  @moduledoc """
  Provides struct and type for a IssuingTransactionAmountDetails
  """

  @type t :: %__MODULE__{atm_fee: integer | nil, cashback_amount: integer | nil}

  defstruct [:atm_fee, :cashback_amount]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [atm_fee: :integer, cashback_amount: :integer]
  end
end
