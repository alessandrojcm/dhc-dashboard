defmodule Dhc.Stripe.CustomerPaymentSourceCard do
  @moduledoc """
  Provides struct and type for a CustomerPaymentSourceCard
  """

  @type t :: %__MODULE__{
          address_city: String.t() | nil,
          address_country: String.t() | nil,
          address_line1: String.t() | nil,
          address_line2: String.t() | nil,
          address_state: String.t() | nil,
          address_zip: String.t() | nil,
          cvc: String.t() | nil,
          encrypted: String.t() | nil,
          exp_month: integer,
          exp_year: integer,
          metadata: map | nil,
          name: String.t() | nil,
          network_token: Dhc.Stripe.SourceDeprecatedCardNetworkToken.t() | nil,
          number: String.t(),
          object: String.t() | nil,
          swipe_data: String.t() | nil
        }

  defstruct [
    :address_city,
    :address_country,
    :address_line1,
    :address_line2,
    :address_state,
    :address_zip,
    :cvc,
    :encrypted,
    :exp_month,
    :exp_year,
    :metadata,
    :name,
    :network_token,
    :number,
    :object,
    :swipe_data
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      address_city: :string,
      address_country: :string,
      address_line1: :string,
      address_line2: :string,
      address_state: :string,
      address_zip: :string,
      cvc: :string,
      encrypted: :string,
      exp_month: :integer,
      exp_year: :integer,
      metadata: :map,
      name: :string,
      network_token: {Dhc.Stripe.SourceDeprecatedCardNetworkToken, :t},
      number: :string,
      object: {:const, "card"},
      swipe_data: :string
    ]
  end
end
