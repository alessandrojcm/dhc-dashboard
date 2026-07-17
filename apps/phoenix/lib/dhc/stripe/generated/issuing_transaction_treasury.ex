defmodule Dhc.Stripe.IssuingTransactionTreasury do
  @moduledoc """
  Provides struct and type for a IssuingTransactionTreasury
  """

  @type t :: %__MODULE__{received_credit: String.t() | nil, received_debit: String.t() | nil}

  defstruct [:received_credit, :received_debit]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [received_credit: :string, received_debit: :string]
  end
end
