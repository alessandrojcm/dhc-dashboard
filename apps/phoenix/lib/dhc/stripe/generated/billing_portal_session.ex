defmodule Dhc.Stripe.BillingPortalSession do
  @moduledoc """
  Provides struct and type for a BillingPortalSession
  """

  @type t :: %__MODULE__{
          configuration: Dhc.Stripe.BillingPortalConfiguration.t() | String.t(),
          created: integer,
          customer: String.t(),
          customer_account: String.t() | nil,
          flow: Dhc.Stripe.PortalFlowsFlow.t() | nil,
          id: String.t(),
          livemode: boolean,
          locale: String.t() | nil,
          object: String.t(),
          on_behalf_of: String.t() | nil,
          return_url: String.t() | nil,
          url: String.t()
        }

  defstruct [
    :configuration,
    :created,
    :customer,
    :customer_account,
    :flow,
    :id,
    :livemode,
    :locale,
    :object,
    :on_behalf_of,
    :return_url,
    :url
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      configuration: {:union, [:string, {Dhc.Stripe.BillingPortalConfiguration, :t}]},
      created: {:integer, "unix-time"},
      customer: :string,
      customer_account: :string,
      flow: {Dhc.Stripe.PortalFlowsFlow, :t},
      id: :string,
      livemode: :boolean,
      locale:
        {:enum,
         [
           "auto",
           "bg",
           "cs",
           "da",
           "de",
           "el",
           "en",
           "en-AU",
           "en-CA",
           "en-GB",
           "en-IE",
           "en-IN",
           "en-NZ",
           "en-SG",
           "es",
           "es-419",
           "et",
           "fi",
           "fil",
           "fr",
           "fr-CA",
           "hr",
           "hu",
           "id",
           "it",
           "ja",
           "ko",
           "lt",
           "lv",
           "ms",
           "mt",
           "nb",
           "nl",
           "pl",
           "pt",
           "pt-BR",
           "ro",
           "ru",
           "sk",
           "sl",
           "sv",
           "th",
           "tr",
           "vi",
           "zh",
           "zh-HK",
           "zh-TW"
         ]},
      object: {:const, "billing_portal.session"},
      on_behalf_of: :string,
      return_url: :string,
      url: :string
    ]
  end
end
