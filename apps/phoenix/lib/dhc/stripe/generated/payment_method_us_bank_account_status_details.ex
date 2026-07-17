defmodule Dhc.Stripe.PaymentMethodUsBankAccountStatusDetails do
  @moduledoc """
  Provides struct and type for a PaymentMethodUsBankAccountStatusDetails
  """

  @type t :: %__MODULE__{blocked: Dhc.Stripe.PaymentMethodUsBankAccountBlocked.t() | nil}

  defstruct [:blocked]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [blocked: {Dhc.Stripe.PaymentMethodUsBankAccountBlocked, :t}]
  end
end
