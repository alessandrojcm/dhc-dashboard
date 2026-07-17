defmodule Dhc.Stripe.PaymentPagesCheckoutSessionAfterExpiration do
  @moduledoc """
  Provides struct and type for a PaymentPagesCheckoutSessionAfterExpiration
  """

  @type t :: %__MODULE__{
          recovery: Dhc.Stripe.PaymentPagesCheckoutSessionAfterExpirationRecovery.t() | nil
        }

  defstruct [:recovery]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [recovery: {Dhc.Stripe.PaymentPagesCheckoutSessionAfterExpirationRecovery, :t}]
  end
end
