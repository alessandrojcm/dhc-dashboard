defmodule Dhc.Stripe.PaymentPagesCheckoutSessionNameCollection do
  @moduledoc """
  Provides struct and type for a PaymentPagesCheckoutSessionNameCollection
  """

  @type t :: %__MODULE__{
          business: Dhc.Stripe.PaymentPagesCheckoutSessionBusinessName.t() | nil,
          individual: Dhc.Stripe.PaymentPagesCheckoutSessionIndividualName.t() | nil
        }

  defstruct [:business, :individual]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      business: {Dhc.Stripe.PaymentPagesCheckoutSessionBusinessName, :t},
      individual: {Dhc.Stripe.PaymentPagesCheckoutSessionIndividualName, :t}
    ]
  end
end
