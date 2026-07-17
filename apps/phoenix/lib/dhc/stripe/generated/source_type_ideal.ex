defmodule Dhc.Stripe.SourceTypeIdeal do
  @moduledoc """
  Provides struct and type for a SourceTypeIdeal
  """

  @type t :: %__MODULE__{
          bank: String.t() | nil,
          bic: String.t() | nil,
          iban_last4: String.t() | nil,
          statement_descriptor: String.t() | nil
        }

  defstruct [:bank, :bic, :iban_last4, :statement_descriptor]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [bank: :string, bic: :string, iban_last4: :string, statement_descriptor: :string]
  end
end
