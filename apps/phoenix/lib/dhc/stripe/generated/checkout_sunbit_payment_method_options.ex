defmodule Dhc.Stripe.CheckoutSunbitPaymentMethodOptions do
  @moduledoc """
  Provides struct and type for a CheckoutSunbitPaymentMethodOptions
  """

  @type t :: %__MODULE__{capture_method: String.t() | nil, setup_future_usage: String.t() | nil}

  defstruct [:capture_method, :setup_future_usage]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [capture_method: {:const, "manual"}, setup_future_usage: {:const, "none"}]
  end
end
