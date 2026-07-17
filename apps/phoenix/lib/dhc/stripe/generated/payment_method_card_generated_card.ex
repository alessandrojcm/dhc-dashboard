defmodule Dhc.Stripe.PaymentMethodCardGeneratedCard do
  @moduledoc """
  Provides struct and type for a PaymentMethodCardGeneratedCard
  """

  @type t :: %__MODULE__{
          charge: String.t() | nil,
          payment_method_details: Dhc.Stripe.CardGeneratedFromPaymentMethodDetails.t() | nil,
          setup_attempt: Dhc.Stripe.SetupAttempt.t() | String.t() | nil
        }

  defstruct [:charge, :payment_method_details, :setup_attempt]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      charge: :string,
      payment_method_details: {Dhc.Stripe.CardGeneratedFromPaymentMethodDetails, :t},
      setup_attempt: {:union, [:string, {Dhc.Stripe.SetupAttempt, :t}]}
    ]
  end
end
