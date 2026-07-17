defmodule Dhc.Stripe.IssuingAuthorizationMerchantData do
  @moduledoc """
  Provides struct and type for a IssuingAuthorizationMerchantData
  """

  @type t :: %__MODULE__{
          category: String.t(),
          category_code: String.t(),
          city: String.t() | nil,
          country: String.t() | nil,
          name: String.t() | nil,
          network_id: String.t(),
          postal_code: String.t() | nil,
          state: String.t() | nil,
          tax_id: String.t() | nil,
          terminal_id: String.t() | nil,
          url: String.t() | nil
        }

  defstruct [
    :category,
    :category_code,
    :city,
    :country,
    :name,
    :network_id,
    :postal_code,
    :state,
    :tax_id,
    :terminal_id,
    :url
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      category: :string,
      category_code: :string,
      city: :string,
      country: :string,
      name: :string,
      network_id: :string,
      postal_code: :string,
      state: :string,
      tax_id: :string,
      terminal_id: :string,
      url: :string
    ]
  end
end
