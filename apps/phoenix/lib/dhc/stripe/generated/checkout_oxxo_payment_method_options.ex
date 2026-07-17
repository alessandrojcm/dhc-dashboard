defmodule Dhc.Stripe.CheckoutOxxoPaymentMethodOptions do
  @moduledoc """
  Provides struct and type for a CheckoutOxxoPaymentMethodOptions
  """

  @type t :: %__MODULE__{expires_after_days: integer, setup_future_usage: String.t() | nil}

  defstruct [:expires_after_days, :setup_future_usage]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [expires_after_days: :integer, setup_future_usage: {:const, "none"}]
  end
end
