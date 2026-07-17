defmodule Dhc.Stripe.TaxDeductedAtSource do
  @moduledoc """
  Provides struct and type for a TaxDeductedAtSource
  """

  @type t :: %__MODULE__{
          id: String.t(),
          object: String.t(),
          period_end: integer,
          period_start: integer,
          tax_deduction_account_number: String.t()
        }

  defstruct [:id, :object, :period_end, :period_start, :tax_deduction_account_number]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      id: :string,
      object: {:const, "tax_deducted_at_source"},
      period_end: {:integer, "unix-time"},
      period_start: {:integer, "unix-time"},
      tax_deduction_account_number: :string
    ]
  end
end
