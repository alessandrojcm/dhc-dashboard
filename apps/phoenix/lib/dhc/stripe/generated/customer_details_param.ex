defmodule Dhc.Stripe.CustomerDetailsParam do
  @moduledoc """
  Provides struct and type for a CustomerDetailsParam
  """

  @type t :: %__MODULE__{
          address: Dhc.Stripe.OptionalFieldsAddress.t() | String.t() | nil,
          shipping: Dhc.Stripe.CustomerShipping.t() | String.t() | nil,
          tax: Dhc.Stripe.TaxParam.t() | nil,
          tax_exempt: String.t() | nil,
          tax_ids: [Dhc.Stripe.DataParams.t()] | nil
        }

  defstruct [:address, :shipping, :tax, :tax_exempt, :tax_ids]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      address: {:union, [{Dhc.Stripe.OptionalFieldsAddress, :t}, const: ""]},
      shipping: {:union, [{Dhc.Stripe.CustomerShipping, :t}, const: ""]},
      tax: {Dhc.Stripe.TaxParam, :t},
      tax_exempt: {:enum, ["", "exempt", "none", "reverse"]},
      tax_ids: [{Dhc.Stripe.DataParams, :t}]
    ]
  end
end
