defmodule Dhc.Stripe.PaymentLinksResourceSubscriptionDataInvoiceSettings do
  @moduledoc """
  Provides struct and type for a PaymentLinksResourceSubscriptionDataInvoiceSettings
  """

  @type t :: %__MODULE__{issuer: Dhc.Stripe.ConnectAccountReference.t()}

  defstruct [:issuer]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [issuer: {Dhc.Stripe.ConnectAccountReference, :t}]
  end
end
