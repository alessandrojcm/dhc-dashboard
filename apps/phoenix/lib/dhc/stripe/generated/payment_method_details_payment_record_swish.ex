defmodule Dhc.Stripe.PaymentMethodDetailsPaymentRecordSwish do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsPaymentRecordSwish
  """

  @type t :: %__MODULE__{
          fingerprint: String.t() | nil,
          payment_reference: String.t() | nil,
          verified_phone_last4: String.t() | nil
        }

  defstruct [:fingerprint, :payment_reference, :verified_phone_last4]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [fingerprint: :string, payment_reference: :string, verified_phone_last4: :string]
  end
end
