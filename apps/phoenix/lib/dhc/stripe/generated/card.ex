defmodule Dhc.Stripe.Card do
  @moduledoc """
  Provides struct and type for a Card
  """

  @type t :: %__MODULE__{
          account: Dhc.Stripe.Account.t() | String.t() | nil,
          address_city: String.t() | nil,
          address_country: String.t() | nil,
          address_line1: String.t() | nil,
          address_line1_check: String.t() | nil,
          address_line2: String.t() | nil,
          address_state: String.t() | nil,
          address_zip: String.t() | nil,
          address_zip_check: String.t() | nil,
          allow_redisplay: String.t() | nil,
          available_payout_methods: [String.t()] | nil,
          brand: String.t(),
          country: String.t() | nil,
          currency: String.t() | nil,
          customer: Dhc.Stripe.Customer.t() | Dhc.Stripe.DeletedCustomer.t() | String.t() | nil,
          cvc_check: String.t() | nil,
          default_for_currency: boolean | nil,
          dynamic_last4: String.t() | nil,
          exp_month: integer,
          exp_year: integer,
          fingerprint: String.t() | nil,
          funding: String.t(),
          id: String.t(),
          iin: String.t() | nil,
          last4: String.t(),
          metadata: map | nil,
          name: String.t() | nil,
          networks: Dhc.Stripe.TokenCardNetworks.t() | nil,
          object: String.t(),
          regulated_status: String.t() | nil,
          status: String.t() | nil,
          tokenization_method: String.t() | nil
        }

  defstruct [
    :account,
    :address_city,
    :address_country,
    :address_line1,
    :address_line1_check,
    :address_line2,
    :address_state,
    :address_zip,
    :address_zip_check,
    :allow_redisplay,
    :available_payout_methods,
    :brand,
    :country,
    :currency,
    :customer,
    :cvc_check,
    :default_for_currency,
    :dynamic_last4,
    :exp_month,
    :exp_year,
    :fingerprint,
    :funding,
    :id,
    :iin,
    :last4,
    :metadata,
    :name,
    :networks,
    :object,
    :regulated_status,
    :status,
    :tokenization_method
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      account: {:union, [:string, {Dhc.Stripe.Account, :t}]},
      address_city: :string,
      address_country: :string,
      address_line1: :string,
      address_line1_check: :string,
      address_line2: :string,
      address_state: :string,
      address_zip: :string,
      address_zip_check: :string,
      allow_redisplay: {:enum, ["always", "limited", "unspecified"]},
      available_payout_methods: [enum: ["instant", "standard"]],
      brand: :string,
      country: :string,
      currency: {:string, "currency"},
      customer: {:union, [:string, {Dhc.Stripe.Customer, :t}, {Dhc.Stripe.DeletedCustomer, :t}]},
      cvc_check: :string,
      default_for_currency: :boolean,
      dynamic_last4: :string,
      exp_month: :integer,
      exp_year: :integer,
      fingerprint: :string,
      funding: :string,
      id: :string,
      iin: :string,
      last4: :string,
      metadata: :map,
      name: :string,
      networks: {Dhc.Stripe.TokenCardNetworks, :t},
      object: {:const, "card"},
      regulated_status: {:enum, ["regulated", "unregulated"]},
      status: :string,
      tokenization_method: :string
    ]
  end
end
