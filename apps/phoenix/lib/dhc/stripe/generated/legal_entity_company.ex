defmodule Dhc.Stripe.LegalEntityCompany do
  @moduledoc """
  Provides struct and type for a LegalEntityCompany
  """

  @type t :: %__MODULE__{
          address: Dhc.Stripe.Address.t() | nil,
          address_kana: Dhc.Stripe.LegalEntityJapanAddress.t() | nil,
          address_kanji: Dhc.Stripe.LegalEntityJapanAddress.t() | nil,
          directors_provided: boolean | nil,
          directorship_declaration: Dhc.Stripe.LegalEntityDirectorshipDeclaration.t() | nil,
          executives_provided: boolean | nil,
          export_license_id: String.t() | nil,
          export_purpose_code: String.t() | nil,
          name: String.t() | nil,
          name_kana: String.t() | nil,
          name_kanji: String.t() | nil,
          owners_provided: boolean | nil,
          ownership_declaration: Dhc.Stripe.LegalEntityUboDeclaration.t() | nil,
          ownership_exemption_reason: String.t() | nil,
          phone: String.t() | nil,
          registration_date: Dhc.Stripe.LegalEntityRegistrationDate.t() | nil,
          representative_declaration: Dhc.Stripe.LegalEntityRepresentativeDeclaration.t() | nil,
          structure: String.t() | nil,
          tax_id_provided: boolean | nil,
          tax_id_registrar: String.t() | nil,
          vat_id_provided: boolean | nil,
          verification: Dhc.Stripe.LegalEntityCompanyVerification.t() | nil
        }

  defstruct [
    :address,
    :address_kana,
    :address_kanji,
    :directors_provided,
    :directorship_declaration,
    :executives_provided,
    :export_license_id,
    :export_purpose_code,
    :name,
    :name_kana,
    :name_kanji,
    :owners_provided,
    :ownership_declaration,
    :ownership_exemption_reason,
    :phone,
    :registration_date,
    :representative_declaration,
    :structure,
    :tax_id_provided,
    :tax_id_registrar,
    :vat_id_provided,
    :verification
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      address: {Dhc.Stripe.Address, :t},
      address_kana: {Dhc.Stripe.LegalEntityJapanAddress, :t},
      address_kanji: {Dhc.Stripe.LegalEntityJapanAddress, :t},
      directors_provided: :boolean,
      directorship_declaration: {Dhc.Stripe.LegalEntityDirectorshipDeclaration, :t},
      executives_provided: :boolean,
      export_license_id: :string,
      export_purpose_code: :string,
      name: :string,
      name_kana: :string,
      name_kanji: :string,
      owners_provided: :boolean,
      ownership_declaration: {Dhc.Stripe.LegalEntityUboDeclaration, :t},
      ownership_exemption_reason:
        {:enum,
         ["qualified_entity_exceeds_ownership_threshold", "qualifies_as_financial_institution"]},
      phone: :string,
      registration_date: {Dhc.Stripe.LegalEntityRegistrationDate, :t},
      representative_declaration: {Dhc.Stripe.LegalEntityRepresentativeDeclaration, :t},
      structure:
        {:enum,
         [
           "free_zone_establishment",
           "free_zone_llc",
           "government_instrumentality",
           "governmental_unit",
           "incorporated_non_profit",
           "incorporated_partnership",
           "limited_liability_partnership",
           "llc",
           "multi_member_llc",
           "private_company",
           "private_corporation",
           "private_partnership",
           "public_company",
           "public_corporation",
           "public_partnership",
           "registered_charity",
           "single_member_llc",
           "sole_establishment",
           "sole_proprietorship",
           "tax_exempt_government_instrumentality",
           "unincorporated_association",
           "unincorporated_non_profit",
           "unincorporated_partnership"
         ]},
      tax_id_provided: :boolean,
      tax_id_registrar: :string,
      vat_id_provided: :boolean,
      verification: {Dhc.Stripe.LegalEntityCompanyVerification, :t}
    ]
  end
end
