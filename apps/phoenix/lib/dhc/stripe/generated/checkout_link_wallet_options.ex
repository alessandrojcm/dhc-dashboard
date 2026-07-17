defmodule Dhc.Stripe.CheckoutLinkWalletOptions do
  @moduledoc """
  Provides struct and type for a CheckoutLinkWalletOptions
  """

  @type t :: %__MODULE__{display: String.t() | nil}

  defstruct [:display]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [display: {:enum, ["auto", "never"]}]
  end
end
