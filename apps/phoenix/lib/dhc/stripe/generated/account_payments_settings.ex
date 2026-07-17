defmodule Dhc.Stripe.AccountPaymentsSettings do
  @moduledoc """
  Provides struct and type for a AccountPaymentsSettings
  """

  @type t :: %__MODULE__{
          statement_descriptor: String.t() | nil,
          statement_descriptor_kana: String.t() | nil,
          statement_descriptor_kanji: String.t() | nil
        }

  defstruct [:statement_descriptor, :statement_descriptor_kana, :statement_descriptor_kanji]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      statement_descriptor: :string,
      statement_descriptor_kana: :string,
      statement_descriptor_kanji: :string
    ]
  end
end
