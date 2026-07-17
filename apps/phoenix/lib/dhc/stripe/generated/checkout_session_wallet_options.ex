defmodule Dhc.Stripe.CheckoutSessionWalletOptions do
  @moduledoc """
  Provides struct and type for a CheckoutSessionWalletOptions
  """

  @type t :: %__MODULE__{link: Dhc.Stripe.CheckoutLinkWalletOptions.t() | nil}

  defstruct [:link]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [link: {Dhc.Stripe.CheckoutLinkWalletOptions, :t}]
  end
end
