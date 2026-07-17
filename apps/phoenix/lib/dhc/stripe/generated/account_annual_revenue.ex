defmodule Dhc.Stripe.AccountAnnualRevenue do
  @moduledoc """
  Provides struct and type for a AccountAnnualRevenue
  """

  @type t :: %__MODULE__{
          amount: integer | nil,
          currency: String.t() | nil,
          fiscal_year_end: String.t() | nil
        }

  defstruct [:amount, :currency, :fiscal_year_end]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [amount: :integer, currency: {:string, "currency"}, fiscal_year_end: :string]
  end
end
