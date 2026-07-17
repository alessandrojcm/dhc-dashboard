defmodule Dhc.Stripe.PaymentMethodOptionsBancontact do
  @moduledoc """
  Provides struct and type for a PaymentMethodOptionsBancontact
  """

  @type t :: %__MODULE__{preferred_language: String.t(), setup_future_usage: String.t() | nil}

  defstruct [:preferred_language, :setup_future_usage]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      preferred_language: {:enum, ["de", "en", "fr", "nl"]},
      setup_future_usage: {:enum, ["none", "off_session"]}
    ]
  end
end
