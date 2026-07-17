defmodule Dhc.Stripe.CheckoutPaytoPaymentMethodOptions do
  @moduledoc """
  Provides struct and type for a CheckoutPaytoPaymentMethodOptions
  """

  @type t :: %__MODULE__{
          mandate_options: Dhc.Stripe.MandateOptionsPayto.t() | nil,
          setup_future_usage: String.t() | nil
        }

  defstruct [:mandate_options, :setup_future_usage]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      mandate_options: {Dhc.Stripe.MandateOptionsPayto, :t},
      setup_future_usage: {:enum, ["none", "off_session"]}
    ]
  end
end
