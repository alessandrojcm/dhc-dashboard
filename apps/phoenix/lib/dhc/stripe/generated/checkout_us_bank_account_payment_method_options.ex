defmodule Dhc.Stripe.CheckoutUsBankAccountPaymentMethodOptions do
  @moduledoc """
  Provides struct and type for a CheckoutUsBankAccountPaymentMethodOptions
  """

  @type t :: %__MODULE__{
          financial_connections: Dhc.Stripe.LinkedAccountOptionsCommon.t() | nil,
          setup_future_usage: String.t() | nil,
          target_date: String.t() | nil,
          verification_method: String.t() | nil
        }

  defstruct [:financial_connections, :setup_future_usage, :target_date, :verification_method]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      financial_connections: {Dhc.Stripe.LinkedAccountOptionsCommon, :t},
      setup_future_usage: {:enum, ["none", "off_session", "on_session"]},
      target_date: :string,
      verification_method: {:enum, ["automatic", "instant"]}
    ]
  end
end
