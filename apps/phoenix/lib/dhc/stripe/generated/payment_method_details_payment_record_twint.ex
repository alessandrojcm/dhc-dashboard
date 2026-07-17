defmodule Dhc.Stripe.PaymentMethodDetailsPaymentRecordTwint do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsPaymentRecordTwint
  """

  @type t :: %__MODULE__{mandate: String.t() | nil}

  defstruct [:mandate]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [mandate: :string]
  end
end
