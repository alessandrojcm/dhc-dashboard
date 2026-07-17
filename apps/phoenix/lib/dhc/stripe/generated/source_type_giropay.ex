defmodule Dhc.Stripe.SourceTypeGiropay do
  @moduledoc """
  Provides struct and type for a SourceTypeGiropay
  """

  @type t :: %__MODULE__{
          bank_code: String.t() | nil,
          bank_name: String.t() | nil,
          bic: String.t() | nil,
          statement_descriptor: String.t() | nil
        }

  defstruct [:bank_code, :bank_name, :bic, :statement_descriptor]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [bank_code: :string, bank_name: :string, bic: :string, statement_descriptor: :string]
  end
end
