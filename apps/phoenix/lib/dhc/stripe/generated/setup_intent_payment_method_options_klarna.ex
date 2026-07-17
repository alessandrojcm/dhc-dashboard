defmodule Dhc.Stripe.SetupIntentPaymentMethodOptionsKlarna do
  @moduledoc """
  Provides struct and type for a SetupIntentPaymentMethodOptionsKlarna
  """

  @type t :: %__MODULE__{currency: String.t() | nil, preferred_locale: String.t() | nil}

  defstruct [:currency, :preferred_locale]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [currency: {:string, "currency"}, preferred_locale: :string]
  end
end
