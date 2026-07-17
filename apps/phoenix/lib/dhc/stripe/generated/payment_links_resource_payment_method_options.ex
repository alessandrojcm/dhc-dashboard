defmodule Dhc.Stripe.PaymentLinksResourcePaymentMethodOptions do
  @moduledoc """
  Provides struct and type for a PaymentLinksResourcePaymentMethodOptions
  """

  @type t :: %__MODULE__{card: Dhc.Stripe.PaymentLinksResourceCardPaymentMethodOptions.t() | nil}

  defstruct [:card]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [card: {Dhc.Stripe.PaymentLinksResourceCardPaymentMethodOptions, :t}]
  end
end
