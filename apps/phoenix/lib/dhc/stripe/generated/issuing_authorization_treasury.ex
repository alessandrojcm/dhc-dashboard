defmodule Dhc.Stripe.IssuingAuthorizationTreasury do
  @moduledoc """
  Provides struct and type for a IssuingAuthorizationTreasury
  """

  @type t :: %__MODULE__{
          received_credits: [String.t()],
          received_debits: [String.t()],
          transaction: String.t() | nil
        }

  defstruct [:received_credits, :received_debits, :transaction]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [received_credits: [:string], received_debits: [:string], transaction: :string]
  end
end
