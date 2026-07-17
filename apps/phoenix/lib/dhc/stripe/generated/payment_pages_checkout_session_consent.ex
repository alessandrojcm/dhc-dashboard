defmodule Dhc.Stripe.PaymentPagesCheckoutSessionConsent do
  @moduledoc """
  Provides struct and type for a PaymentPagesCheckoutSessionConsent
  """

  @type t :: %__MODULE__{promotions: String.t() | nil, terms_of_service: String.t() | nil}

  defstruct [:promotions, :terms_of_service]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [promotions: {:enum, ["opt_in", "opt_out"]}, terms_of_service: {:const, "accepted"}]
  end
end
