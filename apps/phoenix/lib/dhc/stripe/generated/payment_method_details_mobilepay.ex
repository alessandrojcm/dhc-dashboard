defmodule Dhc.Stripe.PaymentMethodDetailsMobilepay do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsMobilepay
  """

  @type t :: %__MODULE__{card: Dhc.Stripe.InternalCard.t() | nil}

  defstruct [:card]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [card: {Dhc.Stripe.InternalCard, :t}]
  end
end
