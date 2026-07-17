defmodule Dhc.Stripe.PaymentMethodOptionsKlarna do
  @moduledoc """
  Provides struct and type for a PaymentMethodOptionsKlarna
  """

  @type t :: %__MODULE__{
          capture_method: String.t() | nil,
          preferred_locale: String.t() | nil,
          setup_future_usage: String.t() | nil
        }

  defstruct [:capture_method, :preferred_locale, :setup_future_usage]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      capture_method: {:const, "manual"},
      preferred_locale: :string,
      setup_future_usage: {:enum, ["none", "off_session", "on_session"]}
    ]
  end
end
