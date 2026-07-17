defmodule Dhc.Stripe.SetupIntentPaymentMethodOptionsParam do
  @moduledoc """
  Provides struct and types for a SetupIntentPaymentMethodOptionsParam
  """

  @type t :: %__MODULE__{
          ares_trans_status: String.t() | nil,
          cryptogram: String.t() | nil,
          currency: String.t() | nil,
          electronic_commerce_indicator: String.t() | nil,
          financial_connections: Dhc.Stripe.LinkedAccountOptionsParam.t() | nil,
          mandate_options:
            Dhc.Stripe.MandateOptionsParam.t()
            | Dhc.Stripe.PaymentMethodOptionsMandateOptionsParam.t()
            | Dhc.Stripe.SetupIntentPaymentMethodOptionsMandateOptionsParam.t()
            | nil,
          network_options: Dhc.Stripe.NetworkOptionsParam.t() | nil,
          networks: Dhc.Stripe.NetworksOptionsParam.t() | nil,
          on_demand: Dhc.Stripe.OnDemandParam.t() | nil,
          preferred_locale: String.t() | nil,
          requestor_challenge_indicator: String.t() | nil,
          subscriptions: String.t() | [map] | nil,
          transaction_id: String.t() | nil,
          verification_method: String.t() | nil,
          version: String.t() | nil
        }

  defstruct [
    :ares_trans_status,
    :cryptogram,
    :currency,
    :electronic_commerce_indicator,
    :financial_connections,
    :mandate_options,
    :network_options,
    :networks,
    :on_demand,
    :preferred_locale,
    :requestor_challenge_indicator,
    :subscriptions,
    :transaction_id,
    :verification_method,
    :version
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      ares_trans_status: {:enum, ["A", "C", "I", "N", "R", "U", "Y"]},
      cryptogram: :string,
      currency: {:union, enum: ["cad", "usd"], string: "currency"},
      electronic_commerce_indicator: {:enum, ["01", "02", "05", "06", "07"]},
      financial_connections: {Dhc.Stripe.LinkedAccountOptionsParam, :t},
      mandate_options:
        {:union,
         [
           {Dhc.Stripe.MandateOptionsParam, :t},
           {Dhc.Stripe.PaymentMethodOptionsMandateOptionsParam, :t},
           {Dhc.Stripe.SetupIntentPaymentMethodOptionsMandateOptionsParam, :t}
         ]},
      network_options: {Dhc.Stripe.NetworkOptionsParam, :t},
      networks: {Dhc.Stripe.NetworksOptionsParam, :t},
      on_demand: {Dhc.Stripe.OnDemandParam, :t},
      preferred_locale:
        {:enum,
         [
           "cs-CZ",
           "da-DK",
           "de-AT",
           "de-CH",
           "de-DE",
           "el-GR",
           "en-AT",
           "en-AU",
           "en-BE",
           "en-CA",
           "en-CH",
           "en-CZ",
           "en-DE",
           "en-DK",
           "en-ES",
           "en-FI",
           "en-FR",
           "en-GB",
           "en-GR",
           "en-IE",
           "en-IT",
           "en-NL",
           "en-NO",
           "en-NZ",
           "en-PL",
           "en-PT",
           "en-RO",
           "en-SE",
           "en-US",
           "es-ES",
           "es-US",
           "fi-FI",
           "fr-BE",
           "fr-CA",
           "fr-CH",
           "fr-FR",
           "it-CH",
           "it-IT",
           "nb-NO",
           "nl-BE",
           "nl-NL",
           "pl-PL",
           "pt-PT",
           "ro-RO",
           "sv-FI",
           "sv-SE"
         ]},
      requestor_challenge_indicator: :string,
      subscriptions: {:union, [{:const, ""}, [:map]]},
      transaction_id: :string,
      verification_method: {:enum, ["automatic", "instant", "microdeposits"]},
      version: {:enum, ["1.0.2", "2.1.0", "2.2.0", "2.3.0", "2.3.1"]}
    ]
  end
end
