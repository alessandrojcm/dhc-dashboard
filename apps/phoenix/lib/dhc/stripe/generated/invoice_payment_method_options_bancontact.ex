defmodule Dhc.Stripe.InvoicePaymentMethodOptionsBancontact do
  @moduledoc """
  Provides struct and type for a InvoicePaymentMethodOptionsBancontact
  """

  @type t :: %__MODULE__{preferred_language: String.t()}

  defstruct [:preferred_language]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [preferred_language: {:enum, ["de", "en", "fr", "nl"]}]
  end
end
