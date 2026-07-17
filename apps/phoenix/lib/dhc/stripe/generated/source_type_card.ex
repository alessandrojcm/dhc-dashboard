defmodule Dhc.Stripe.SourceTypeCard do
  @moduledoc """
  Provides struct and type for a SourceTypeCard
  """

  @type t :: %__MODULE__{
          address_line1_check: String.t() | nil,
          address_zip_check: String.t() | nil,
          brand: String.t() | nil,
          country: String.t() | nil,
          cvc_check: String.t() | nil,
          dynamic_last4: String.t() | nil,
          exp_month: integer | nil,
          exp_year: integer | nil,
          fingerprint: String.t() | nil,
          funding: String.t() | nil,
          last4: String.t() | nil,
          name: String.t() | nil,
          three_d_secure: String.t() | nil,
          tokenization_method: String.t() | nil
        }

  defstruct [
    :address_line1_check,
    :address_zip_check,
    :brand,
    :country,
    :cvc_check,
    :dynamic_last4,
    :exp_month,
    :exp_year,
    :fingerprint,
    :funding,
    :last4,
    :name,
    :three_d_secure,
    :tokenization_method
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      address_line1_check: :string,
      address_zip_check: :string,
      brand: :string,
      country: :string,
      cvc_check: :string,
      dynamic_last4: :string,
      exp_month: :integer,
      exp_year: :integer,
      fingerprint: :string,
      funding: :string,
      last4: :string,
      name: :string,
      three_d_secure: :string,
      tokenization_method: :string
    ]
  end
end
