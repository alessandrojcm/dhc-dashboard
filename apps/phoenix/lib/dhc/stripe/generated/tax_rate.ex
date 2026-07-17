defmodule Dhc.Stripe.TaxRate do
  @moduledoc """
  Provides struct and type for a TaxRate
  """

  @type t :: %__MODULE__{
          active: boolean,
          country: String.t() | nil,
          created: integer,
          description: String.t() | nil,
          display_name: String.t(),
          effective_percentage: number | nil,
          flat_amount: Dhc.Stripe.TaxRateFlatAmount.t() | nil,
          id: String.t(),
          inclusive: boolean,
          jurisdiction: String.t() | nil,
          jurisdiction_level: String.t() | nil,
          livemode: boolean,
          metadata: map | nil,
          object: String.t(),
          percentage: number,
          rate_type: String.t() | nil,
          state: String.t() | nil,
          tax_type: String.t() | nil
        }

  defstruct [
    :active,
    :country,
    :created,
    :description,
    :display_name,
    :effective_percentage,
    :flat_amount,
    :id,
    :inclusive,
    :jurisdiction,
    :jurisdiction_level,
    :livemode,
    :metadata,
    :object,
    :percentage,
    :rate_type,
    :state,
    :tax_type
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      active: :boolean,
      country: :string,
      created: {:integer, "unix-time"},
      description: :string,
      display_name: :string,
      effective_percentage: :number,
      flat_amount: {Dhc.Stripe.TaxRateFlatAmount, :t},
      id: :string,
      inclusive: :boolean,
      jurisdiction: :string,
      jurisdiction_level: {:enum, ["city", "country", "county", "district", "multiple", "state"]},
      livemode: :boolean,
      metadata: :map,
      object: {:const, "tax_rate"},
      percentage: :number,
      rate_type: {:enum, ["flat_amount", "percentage"]},
      state: :string,
      tax_type:
        {:enum,
         [
           "amusement_tax",
           "communications_tax",
           "gst",
           "hst",
           "igst",
           "jct",
           "lease_tax",
           "pst",
           "qst",
           "retail_delivery_fee",
           "rst",
           "sales_tax",
           "service_tax",
           "vat"
         ]}
    ]
  end
end
