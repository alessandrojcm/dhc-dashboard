defmodule Dhc.Stripe.SourceTypeMultibanco do
  @moduledoc """
  Provides struct and type for a SourceTypeMultibanco
  """

  @type t :: %__MODULE__{
          entity: String.t() | nil,
          reference: String.t() | nil,
          refund_account_holder_address_city: String.t() | nil,
          refund_account_holder_address_country: String.t() | nil,
          refund_account_holder_address_line1: String.t() | nil,
          refund_account_holder_address_line2: String.t() | nil,
          refund_account_holder_address_postal_code: String.t() | nil,
          refund_account_holder_address_state: String.t() | nil,
          refund_account_holder_name: String.t() | nil,
          refund_iban: String.t() | nil
        }

  defstruct [
    :entity,
    :reference,
    :refund_account_holder_address_city,
    :refund_account_holder_address_country,
    :refund_account_holder_address_line1,
    :refund_account_holder_address_line2,
    :refund_account_holder_address_postal_code,
    :refund_account_holder_address_state,
    :refund_account_holder_name,
    :refund_iban
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      entity: :string,
      reference: :string,
      refund_account_holder_address_city: :string,
      refund_account_holder_address_country: :string,
      refund_account_holder_address_line1: :string,
      refund_account_holder_address_line2: :string,
      refund_account_holder_address_postal_code: :string,
      refund_account_holder_address_state: :string,
      refund_account_holder_name: :string,
      refund_iban: :string
    ]
  end
end
