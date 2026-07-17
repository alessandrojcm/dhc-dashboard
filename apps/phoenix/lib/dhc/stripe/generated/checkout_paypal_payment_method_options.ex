defmodule Dhc.Stripe.CheckoutPaypalPaymentMethodOptions do
  @moduledoc """
  Provides struct and type for a CheckoutPaypalPaymentMethodOptions
  """

  @type t :: %__MODULE__{
          capture_method: String.t() | nil,
          preferred_locale: String.t() | nil,
          reference: String.t() | nil,
          setup_future_usage: String.t() | nil
        }

  defstruct [:capture_method, :preferred_locale, :reference, :setup_future_usage]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      capture_method: {:const, "manual"},
      preferred_locale: :string,
      reference: :string,
      setup_future_usage: {:enum, ["none", "off_session"]}
    ]
  end
end
