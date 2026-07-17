defmodule Dhc.Stripe.IssuingPersonalizationDesignRejectionReasons do
  @moduledoc """
  Provides struct and type for a IssuingPersonalizationDesignRejectionReasons
  """

  @type t :: %__MODULE__{card_logo: [String.t()] | nil, carrier_text: [String.t()] | nil}

  defstruct [:card_logo, :carrier_text]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      card_logo: [
        enum: [
          "geographic_location",
          "inappropriate",
          "network_name",
          "non_binary_image",
          "non_fiat_currency",
          "other",
          "other_entity",
          "promotional_material"
        ]
      ],
      carrier_text: [
        enum: [
          "geographic_location",
          "inappropriate",
          "network_name",
          "non_fiat_currency",
          "other",
          "other_entity",
          "promotional_material"
        ]
      ]
    ]
  end
end
