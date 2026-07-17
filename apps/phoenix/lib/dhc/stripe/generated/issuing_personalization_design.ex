defmodule Dhc.Stripe.IssuingPersonalizationDesign do
  @moduledoc """
  Provides struct and type for a IssuingPersonalizationDesign
  """

  @type t :: %__MODULE__{
          card_logo: Dhc.Stripe.File.t() | String.t() | nil,
          carrier_text: Dhc.Stripe.IssuingPersonalizationDesignCarrierText.t() | nil,
          created: integer,
          id: String.t(),
          livemode: boolean,
          lookup_key: String.t() | nil,
          metadata: map,
          name: String.t() | nil,
          object: String.t(),
          physical_bundle: Dhc.Stripe.IssuingPhysicalBundle.t() | String.t(),
          preferences: Dhc.Stripe.IssuingPersonalizationDesignPreferences.t(),
          rejection_reasons: Dhc.Stripe.IssuingPersonalizationDesignRejectionReasons.t(),
          status: String.t()
        }

  defstruct [
    :card_logo,
    :carrier_text,
    :created,
    :id,
    :livemode,
    :lookup_key,
    :metadata,
    :name,
    :object,
    :physical_bundle,
    :preferences,
    :rejection_reasons,
    :status
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      card_logo: {:union, [:string, {Dhc.Stripe.File, :t}]},
      carrier_text: {Dhc.Stripe.IssuingPersonalizationDesignCarrierText, :t},
      created: {:integer, "unix-time"},
      id: :string,
      livemode: :boolean,
      lookup_key: :string,
      metadata: :map,
      name: :string,
      object: {:const, "issuing.personalization_design"},
      physical_bundle: {:union, [:string, {Dhc.Stripe.IssuingPhysicalBundle, :t}]},
      preferences: {Dhc.Stripe.IssuingPersonalizationDesignPreferences, :t},
      rejection_reasons: {Dhc.Stripe.IssuingPersonalizationDesignRejectionReasons, :t},
      status: {:enum, ["active", "inactive", "rejected", "review"]}
    ]
  end
end
