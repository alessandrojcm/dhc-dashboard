defmodule Dhc.Stripe.SourceTypeAcssDebit do
  @moduledoc """
  Provides struct and type for a SourceTypeAcssDebit
  """

  @type t :: %__MODULE__{
          bank_address_city: String.t() | nil,
          bank_address_line_1: String.t() | nil,
          bank_address_line_2: String.t() | nil,
          bank_address_postal_code: String.t() | nil,
          bank_name: String.t() | nil,
          category: String.t() | nil,
          country: String.t() | nil,
          fingerprint: String.t() | nil,
          last4: String.t() | nil,
          routing_number: String.t() | nil
        }

  defstruct [
    :bank_address_city,
    :bank_address_line_1,
    :bank_address_line_2,
    :bank_address_postal_code,
    :bank_name,
    :category,
    :country,
    :fingerprint,
    :last4,
    :routing_number
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      bank_address_city: :string,
      bank_address_line_1: :string,
      bank_address_line_2: :string,
      bank_address_postal_code: :string,
      bank_name: :string,
      category: :string,
      country: :string,
      fingerprint: :string,
      last4: :string,
      routing_number: :string
    ]
  end
end
