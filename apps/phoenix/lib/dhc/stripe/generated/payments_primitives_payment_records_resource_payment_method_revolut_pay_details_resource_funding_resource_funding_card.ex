defmodule Dhc.Stripe.PaymentsPrimitivesPaymentRecordsResourcePaymentMethodRevolutPayDetailsResourceFundingResourceFundingCard do
  @moduledoc """
  Provides struct and type for a PaymentsPrimitivesPaymentRecordsResourcePaymentMethodRevolutPayDetailsResourceFundingResourceFundingCard
  """

  @type t :: %__MODULE__{
          brand: String.t() | nil,
          country: String.t() | nil,
          exp_month: integer | nil,
          exp_year: integer | nil,
          funding: String.t() | nil,
          last4: String.t() | nil
        }

  defstruct [:brand, :country, :exp_month, :exp_year, :funding, :last4]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      brand: :string,
      country: :string,
      exp_month: :integer,
      exp_year: :integer,
      funding: :string,
      last4: :string
    ]
  end
end
