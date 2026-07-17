defmodule Dhc.Stripe.Person do
  @moduledoc """
  Provides struct and type for a Person
  """

  @type t :: %__MODULE__{
          account: String.t(),
          additional_tos_acceptances: Dhc.Stripe.PersonAdditionalTosAcceptances.t() | nil,
          address: Dhc.Stripe.Address.t() | nil,
          address_kana: Dhc.Stripe.LegalEntityJapanAddress.t() | nil,
          address_kanji: Dhc.Stripe.LegalEntityJapanAddress.t() | nil,
          created: integer,
          dob: Dhc.Stripe.LegalEntityDob.t() | nil,
          email: String.t() | nil,
          first_name: String.t() | nil,
          first_name_kana: String.t() | nil,
          first_name_kanji: String.t() | nil,
          full_name_aliases: [String.t()] | nil,
          future_requirements: Dhc.Stripe.PersonFutureRequirements.t() | nil,
          gender: String.t() | nil,
          id: String.t(),
          id_number_provided: boolean | nil,
          id_number_secondary_provided: boolean | nil,
          last_name: String.t() | nil,
          last_name_kana: String.t() | nil,
          last_name_kanji: String.t() | nil,
          maiden_name: String.t() | nil,
          metadata: map | nil,
          nationality: String.t() | nil,
          object: String.t(),
          phone: String.t() | nil,
          political_exposure: String.t() | nil,
          registered_address: Dhc.Stripe.Address.t() | nil,
          relationship: Dhc.Stripe.PersonRelationship.t() | nil,
          requirements: Dhc.Stripe.PersonRequirements.t() | nil,
          ssn_last_4_provided: boolean | nil,
          us_cfpb_data: Dhc.Stripe.PersonUsCfpbData.t() | nil,
          verification: Dhc.Stripe.LegalEntityPersonVerification.t() | nil
        }

  defstruct [
    :account,
    :additional_tos_acceptances,
    :address,
    :address_kana,
    :address_kanji,
    :created,
    :dob,
    :email,
    :first_name,
    :first_name_kana,
    :first_name_kanji,
    :full_name_aliases,
    :future_requirements,
    :gender,
    :id,
    :id_number_provided,
    :id_number_secondary_provided,
    :last_name,
    :last_name_kana,
    :last_name_kanji,
    :maiden_name,
    :metadata,
    :nationality,
    :object,
    :phone,
    :political_exposure,
    :registered_address,
    :relationship,
    :requirements,
    :ssn_last_4_provided,
    :us_cfpb_data,
    :verification
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      account: :string,
      additional_tos_acceptances: {Dhc.Stripe.PersonAdditionalTosAcceptances, :t},
      address: {Dhc.Stripe.Address, :t},
      address_kana: {Dhc.Stripe.LegalEntityJapanAddress, :t},
      address_kanji: {Dhc.Stripe.LegalEntityJapanAddress, :t},
      created: {:integer, "unix-time"},
      dob: {Dhc.Stripe.LegalEntityDob, :t},
      email: :string,
      first_name: :string,
      first_name_kana: :string,
      first_name_kanji: :string,
      full_name_aliases: [:string],
      future_requirements: {Dhc.Stripe.PersonFutureRequirements, :t},
      gender: :string,
      id: :string,
      id_number_provided: :boolean,
      id_number_secondary_provided: :boolean,
      last_name: :string,
      last_name_kana: :string,
      last_name_kanji: :string,
      maiden_name: :string,
      metadata: :map,
      nationality: :string,
      object: {:const, "person"},
      phone: :string,
      political_exposure: {:enum, ["existing", "none"]},
      registered_address: {Dhc.Stripe.Address, :t},
      relationship: {Dhc.Stripe.PersonRelationship, :t},
      requirements: {Dhc.Stripe.PersonRequirements, :t},
      ssn_last_4_provided: :boolean,
      us_cfpb_data: {Dhc.Stripe.PersonUsCfpbData, :t},
      verification: {Dhc.Stripe.LegalEntityPersonVerification, :t}
    ]
  end
end
