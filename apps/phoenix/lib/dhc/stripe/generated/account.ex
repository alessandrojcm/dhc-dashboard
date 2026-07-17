defmodule Dhc.Stripe.Account do
  @moduledoc """
  Provides struct and type for a Account
  """

  @type t :: %__MODULE__{
          business_profile: Dhc.Stripe.AccountBusinessProfile.t() | nil,
          business_type: String.t() | nil,
          capabilities: Dhc.Stripe.AccountCapabilities.t() | nil,
          charges_enabled: boolean | nil,
          company: Dhc.Stripe.LegalEntityCompany.t() | nil,
          controller: Dhc.Stripe.AccountUnificationAccountController.t() | nil,
          country: String.t() | nil,
          created: integer | nil,
          default_currency: String.t() | nil,
          details_submitted: boolean | nil,
          email: String.t() | nil,
          external_accounts: Dhc.Stripe.ExternalAccountList.t() | nil,
          future_requirements: Dhc.Stripe.AccountFutureRequirements.t() | nil,
          groups: Dhc.Stripe.AccountGroupMembership.t() | nil,
          id: String.t(),
          individual: Dhc.Stripe.Person.t() | nil,
          metadata: map | nil,
          object: String.t(),
          payouts_enabled: boolean | nil,
          requirements: Dhc.Stripe.AccountRequirements.t() | nil,
          settings: Dhc.Stripe.AccountSettings.t() | nil,
          tos_acceptance: Dhc.Stripe.AccountTosAcceptance.t() | nil,
          type: String.t() | nil
        }

  defstruct [
    :business_profile,
    :business_type,
    :capabilities,
    :charges_enabled,
    :company,
    :controller,
    :country,
    :created,
    :default_currency,
    :details_submitted,
    :email,
    :external_accounts,
    :future_requirements,
    :groups,
    :id,
    :individual,
    :metadata,
    :object,
    :payouts_enabled,
    :requirements,
    :settings,
    :tos_acceptance,
    :type
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      business_profile: {Dhc.Stripe.AccountBusinessProfile, :t},
      business_type: {:enum, ["company", "government_entity", "individual", "non_profit"]},
      capabilities: {Dhc.Stripe.AccountCapabilities, :t},
      charges_enabled: :boolean,
      company: {Dhc.Stripe.LegalEntityCompany, :t},
      controller: {Dhc.Stripe.AccountUnificationAccountController, :t},
      country: :string,
      created: {:integer, "unix-time"},
      default_currency: :string,
      details_submitted: :boolean,
      email: :string,
      external_accounts: {Dhc.Stripe.ExternalAccountList, :t},
      future_requirements: {Dhc.Stripe.AccountFutureRequirements, :t},
      groups: {Dhc.Stripe.AccountGroupMembership, :t},
      id: :string,
      individual: {Dhc.Stripe.Person, :t},
      metadata: :map,
      object: {:const, "account"},
      payouts_enabled: :boolean,
      requirements: {Dhc.Stripe.AccountRequirements, :t},
      settings: {Dhc.Stripe.AccountSettings, :t},
      tos_acceptance: {Dhc.Stripe.AccountTosAcceptance, :t},
      type: {:enum, ["custom", "express", "none", "standard"]}
    ]
  end
end
