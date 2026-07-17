defmodule Dhc.Stripe.AccountSepaDebitPaymentsSettings do
  @moduledoc """
  Provides struct and type for a AccountSepaDebitPaymentsSettings
  """

  @type t :: %__MODULE__{creditor_id: String.t() | nil}

  defstruct [:creditor_id]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [creditor_id: :string]
  end
end
