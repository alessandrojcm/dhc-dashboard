defmodule Dhc.Stripe.PaymentLinksResourceNameCollection do
  @moduledoc """
  Provides struct and type for a PaymentLinksResourceNameCollection
  """

  @type t :: %__MODULE__{
          business: Dhc.Stripe.PaymentLinksResourceBusinessName.t() | nil,
          individual: Dhc.Stripe.PaymentLinksResourceIndividualName.t() | nil
        }

  defstruct [:business, :individual]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      business: {Dhc.Stripe.PaymentLinksResourceBusinessName, :t},
      individual: {Dhc.Stripe.PaymentLinksResourceIndividualName, :t}
    ]
  end
end
