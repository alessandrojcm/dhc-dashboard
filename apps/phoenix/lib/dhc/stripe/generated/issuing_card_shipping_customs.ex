defmodule Dhc.Stripe.IssuingCardShippingCustoms do
  @moduledoc """
  Provides struct and type for a IssuingCardShippingCustoms
  """

  @type t :: %__MODULE__{eori_number: String.t() | nil}

  defstruct [:eori_number]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [eori_number: :string]
  end
end
