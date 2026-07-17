defmodule Dhc.Stripe.PaymentMethodDetailsKonbini do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsKonbini
  """

  @type t :: %__MODULE__{store: Dhc.Stripe.PaymentMethodDetailsKonbiniStore.t() | nil}

  defstruct [:store]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [store: {Dhc.Stripe.PaymentMethodDetailsKonbiniStore, :t}]
  end
end
