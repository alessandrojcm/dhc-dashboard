defmodule Dhc.Stripe.SetupAttemptPaymentMethodDetailsCardPresent do
  @moduledoc """
  Provides struct and type for a SetupAttemptPaymentMethodDetailsCardPresent
  """

  @type t :: %__MODULE__{
          generated_card: Dhc.Stripe.PaymentMethod.t() | String.t() | nil,
          offline: Dhc.Stripe.PaymentMethodDetailsCardPresentOffline.t() | nil
        }

  defstruct [:generated_card, :offline]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      generated_card: {:union, [:string, {Dhc.Stripe.PaymentMethod, :t}]},
      offline: {Dhc.Stripe.PaymentMethodDetailsCardPresentOffline, :t}
    ]
  end
end
