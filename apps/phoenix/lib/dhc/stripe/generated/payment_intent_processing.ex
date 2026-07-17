defmodule Dhc.Stripe.PaymentIntentProcessing do
  @moduledoc """
  Provides struct and type for a PaymentIntentProcessing
  """

  @type t :: %__MODULE__{card: Dhc.Stripe.PaymentIntentCardProcessing.t() | nil, type: String.t()}

  defstruct [:card, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [card: {Dhc.Stripe.PaymentIntentCardProcessing, :t}, type: {:const, "card"}]
  end
end
