defmodule Dhc.Stripe.SubscriptionPaymentMethodOptionsPix do
  @moduledoc """
  Provides struct and type for a SubscriptionPaymentMethodOptionsPix
  """

  @type t :: %__MODULE__{
          expires_after_seconds: integer | nil,
          mandate_options: Dhc.Stripe.SubscriptionPaymentMethodOptionsMandateOptionsPix.t() | nil
        }

  defstruct [:expires_after_seconds, :mandate_options]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      expires_after_seconds: :integer,
      mandate_options: {Dhc.Stripe.SubscriptionPaymentMethodOptionsMandateOptionsPix, :t}
    ]
  end
end
