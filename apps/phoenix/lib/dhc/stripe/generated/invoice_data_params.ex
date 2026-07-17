defmodule Dhc.Stripe.InvoiceDataParams do
  @moduledoc """
  Provides struct and type for a InvoiceDataParams
  """

  @type t :: %__MODULE__{
          account_tax_ids: String.t() | [String.t()] | nil,
          custom_fields: String.t() | [map] | nil,
          description: String.t() | nil,
          footer: String.t() | nil,
          issuer: Dhc.Stripe.Param.t() | nil,
          metadata: map | nil,
          rendering_options: Dhc.Stripe.CheckoutRenderingOptionsParam.t() | String.t() | nil
        }

  defstruct [
    :account_tax_ids,
    :custom_fields,
    :description,
    :footer,
    :issuer,
    :metadata,
    :rendering_options
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      account_tax_ids: {:union, [{:const, ""}, [:string]]},
      custom_fields: {:union, [{:const, ""}, [:map]]},
      description: :string,
      footer: :string,
      issuer: {Dhc.Stripe.Param, :t},
      metadata: :map,
      rendering_options: {:union, [{Dhc.Stripe.CheckoutRenderingOptionsParam, :t}, const: ""]}
    ]
  end
end
