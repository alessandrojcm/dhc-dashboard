defmodule Dhc.Stripe.SourceTypeSofort do
  @moduledoc """
  Provides struct and type for a SourceTypeSofort
  """

  @type t :: %__MODULE__{
          bank_code: String.t() | nil,
          bank_name: String.t() | nil,
          bic: String.t() | nil,
          country: String.t() | nil,
          iban_last4: String.t() | nil,
          preferred_language: String.t() | nil,
          statement_descriptor: String.t() | nil
        }

  defstruct [
    :bank_code,
    :bank_name,
    :bic,
    :country,
    :iban_last4,
    :preferred_language,
    :statement_descriptor
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      bank_code: :string,
      bank_name: :string,
      bic: :string,
      country: :string,
      iban_last4: :string,
      preferred_language: :string,
      statement_descriptor: :string
    ]
  end
end
