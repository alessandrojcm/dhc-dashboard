defmodule Dhc.Stripe.CheckoutWechatPayPaymentMethodOptions do
  @moduledoc """
  Provides struct and type for a CheckoutWechatPayPaymentMethodOptions
  """

  @type t :: %__MODULE__{
          app_id: String.t() | nil,
          client: String.t() | nil,
          setup_future_usage: String.t() | nil
        }

  defstruct [:app_id, :client, :setup_future_usage]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      app_id: :string,
      client: {:enum, ["android", "ios", "web"]},
      setup_future_usage: {:const, "none"}
    ]
  end
end
