defmodule Dhc.Stripe.InvoiceMandateOptionsCard do
  @moduledoc """
  Provides struct and type for a InvoiceMandateOptionsCard
  """

  @type t :: %__MODULE__{
          amount: integer | nil,
          amount_type: String.t() | nil,
          description: String.t() | nil
        }

  defstruct [:amount, :amount_type, :description]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [amount: :integer, amount_type: {:enum, ["fixed", "maximum"]}, description: :string]
  end
end
