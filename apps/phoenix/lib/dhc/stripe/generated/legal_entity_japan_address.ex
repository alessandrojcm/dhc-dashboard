defmodule Dhc.Stripe.LegalEntityJapanAddress do
  @moduledoc """
  Provides struct and type for a LegalEntityJapanAddress
  """

  @type t :: %__MODULE__{
          city: String.t() | nil,
          country: String.t() | nil,
          line1: String.t() | nil,
          line2: String.t() | nil,
          postal_code: String.t() | nil,
          state: String.t() | nil,
          town: String.t() | nil
        }

  defstruct [:city, :country, :line1, :line2, :postal_code, :state, :town]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      city: :string,
      country: :string,
      line1: :string,
      line2: :string,
      postal_code: :string,
      state: :string,
      town: :string
    ]
  end
end
