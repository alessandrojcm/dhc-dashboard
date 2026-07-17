defmodule Dhc.Stripe.IssuingCardholderCompany do
  @moduledoc """
  Provides struct and type for a IssuingCardholderCompany
  """

  @type t :: %__MODULE__{tax_id_provided: boolean}

  defstruct [:tax_id_provided]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [tax_id_provided: :boolean]
  end
end
