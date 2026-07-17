defmodule Dhc.Stripe.PaymentIntentCardProcessing do
  @moduledoc """
  Provides struct and type for a PaymentIntentCardProcessing
  """

  @type t :: %__MODULE__{
          customer_notification: Dhc.Stripe.PaymentIntentProcessingCustomerNotification.t() | nil
        }

  defstruct [:customer_notification]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [customer_notification: {Dhc.Stripe.PaymentIntentProcessingCustomerNotification, :t}]
  end
end
