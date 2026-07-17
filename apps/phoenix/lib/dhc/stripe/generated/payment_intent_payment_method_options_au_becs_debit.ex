defmodule Dhc.Stripe.PaymentIntentPaymentMethodOptionsAuBecsDebit do
  @moduledoc """
  Provides struct and type for a PaymentIntentPaymentMethodOptionsAuBecsDebit
  """

  @type t :: %__MODULE__{setup_future_usage: String.t() | nil, target_date: String.t() | nil}

  defstruct [:setup_future_usage, :target_date]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [setup_future_usage: {:enum, ["none", "off_session", "on_session"]}, target_date: :string]
  end
end
