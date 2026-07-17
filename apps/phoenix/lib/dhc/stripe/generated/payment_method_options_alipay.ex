defmodule Dhc.Stripe.PaymentMethodOptionsAlipay do
  @moduledoc """
  Provides struct and type for a PaymentMethodOptionsAlipay
  """

  @type t :: %__MODULE__{setup_future_usage: String.t() | nil}

  defstruct [:setup_future_usage]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [setup_future_usage: {:enum, ["none", "off_session"]}]
  end
end
