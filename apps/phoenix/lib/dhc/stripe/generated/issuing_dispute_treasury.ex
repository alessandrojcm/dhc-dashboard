defmodule Dhc.Stripe.IssuingDisputeTreasury do
  @moduledoc """
  Provides struct and type for a IssuingDisputeTreasury
  """

  @type t :: %__MODULE__{debit_reversal: String.t() | nil, received_debit: String.t()}

  defstruct [:debit_reversal, :received_debit]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [debit_reversal: :string, received_debit: :string]
  end
end
