defmodule Dhc.Stripe.PaymentIntentPaymentMethodOptionsSwish do
  @moduledoc """
  Provides struct and type for a PaymentIntentPaymentMethodOptionsSwish
  """

  @type t :: %__MODULE__{reference: String.t() | nil, setup_future_usage: String.t() | nil}

  defstruct [:reference, :setup_future_usage]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [reference: :string, setup_future_usage: {:const, "none"}]
  end
end
