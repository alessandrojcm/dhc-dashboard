defmodule Dhc.Stripe.PaymentLinksResourceCardPaymentMethodOptions do
  @moduledoc """
  Provides struct and type for a PaymentLinksResourceCardPaymentMethodOptions
  """

  @type t :: %__MODULE__{restrictions: Dhc.Stripe.PaymentLinksResourceCardRestrictions.t() | nil}

  defstruct [:restrictions]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [restrictions: {Dhc.Stripe.PaymentLinksResourceCardRestrictions, :t}]
  end
end
