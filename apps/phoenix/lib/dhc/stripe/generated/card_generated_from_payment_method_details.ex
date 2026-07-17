defmodule Dhc.Stripe.CardGeneratedFromPaymentMethodDetails do
  @moduledoc """
  Provides struct and type for a CardGeneratedFromPaymentMethodDetails
  """

  @type t :: %__MODULE__{
          card_present: Dhc.Stripe.PaymentMethodDetailsCardPresent.t() | nil,
          type: String.t()
        }

  defstruct [:card_present, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [card_present: {Dhc.Stripe.PaymentMethodDetailsCardPresent, :t}, type: :string]
  end
end
