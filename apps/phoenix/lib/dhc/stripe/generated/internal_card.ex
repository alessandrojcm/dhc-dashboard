defmodule Dhc.Stripe.InternalCard do
  @moduledoc """
  Provides struct and type for a InternalCard
  """

  @type t :: %__MODULE__{
          brand: String.t() | nil,
          country: String.t() | nil,
          exp_month: integer | nil,
          exp_year: integer | nil,
          last4: String.t() | nil
        }

  defstruct [:brand, :country, :exp_month, :exp_year, :last4]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [brand: :string, country: :string, exp_month: :integer, exp_year: :integer, last4: :string]
  end
end
