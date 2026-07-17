defmodule Dhc.Stripe.Product do
  @moduledoc """
  Provides struct and type for a Product
  """

  @type t :: %__MODULE__{
          active: boolean,
          created: integer,
          default_price: Dhc.Stripe.Price.t() | String.t() | nil,
          description: String.t() | nil,
          id: String.t(),
          images: [String.t()],
          livemode: boolean,
          marketing_features: [Dhc.Stripe.ProductMarketingFeature.t()],
          metadata: map,
          name: String.t(),
          object: String.t(),
          package_dimensions: Dhc.Stripe.PackageDimensions.t() | nil,
          shippable: boolean | nil,
          statement_descriptor: String.t() | nil,
          tax_code: Dhc.Stripe.TaxCode.t() | String.t() | nil,
          unit_label: String.t() | nil,
          updated: integer,
          url: String.t() | nil
        }

  defstruct [
    :active,
    :created,
    :default_price,
    :description,
    :id,
    :images,
    :livemode,
    :marketing_features,
    :metadata,
    :name,
    :object,
    :package_dimensions,
    :shippable,
    :statement_descriptor,
    :tax_code,
    :unit_label,
    :updated,
    :url
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      active: :boolean,
      created: {:integer, "unix-time"},
      default_price: {:union, [:string, {Dhc.Stripe.Price, :t}]},
      description: :string,
      id: :string,
      images: [:string],
      livemode: :boolean,
      marketing_features: [{Dhc.Stripe.ProductMarketingFeature, :t}],
      metadata: :map,
      name: :string,
      object: {:const, "product"},
      package_dimensions: {Dhc.Stripe.PackageDimensions, :t},
      shippable: :boolean,
      statement_descriptor: :string,
      tax_code: {:union, [:string, {Dhc.Stripe.TaxCode, :t}]},
      unit_label: :string,
      updated: {:integer, "unix-time"},
      url: :string
    ]
  end
end
