defmodule Dhc.Stripe.BillingPortalConfiguration do
  @moduledoc """
  Provides struct and type for a BillingPortalConfiguration
  """

  @type t :: %__MODULE__{
          active: boolean,
          application:
            Dhc.Stripe.Application.t() | Dhc.Stripe.DeletedApplication.t() | String.t() | nil,
          business_profile: Dhc.Stripe.PortalBusinessProfile.t(),
          created: integer,
          default_return_url: String.t() | nil,
          features: Dhc.Stripe.PortalFeatures.t(),
          id: String.t(),
          is_default: boolean,
          livemode: boolean,
          login_page: Dhc.Stripe.PortalLoginPage.t(),
          metadata: map | nil,
          name: String.t() | nil,
          object: String.t(),
          updated: integer
        }

  defstruct [
    :active,
    :application,
    :business_profile,
    :created,
    :default_return_url,
    :features,
    :id,
    :is_default,
    :livemode,
    :login_page,
    :metadata,
    :name,
    :object,
    :updated
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      active: :boolean,
      application:
        {:union, [:string, {Dhc.Stripe.Application, :t}, {Dhc.Stripe.DeletedApplication, :t}]},
      business_profile: {Dhc.Stripe.PortalBusinessProfile, :t},
      created: {:integer, "unix-time"},
      default_return_url: :string,
      features: {Dhc.Stripe.PortalFeatures, :t},
      id: :string,
      is_default: :boolean,
      livemode: :boolean,
      login_page: {Dhc.Stripe.PortalLoginPage, :t},
      metadata: :map,
      name: :string,
      object: {:const, "billing_portal.configuration"},
      updated: {:integer, "unix-time"}
    ]
  end
end
