defmodule Dhc.Stripe.IssuingCardholderVerification do
  @moduledoc """
  Provides struct and type for a IssuingCardholderVerification
  """

  @type t :: %__MODULE__{document: Dhc.Stripe.IssuingCardholderIdDocument.t() | nil}

  defstruct [:document]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [document: {Dhc.Stripe.IssuingCardholderIdDocument, :t}]
  end
end
