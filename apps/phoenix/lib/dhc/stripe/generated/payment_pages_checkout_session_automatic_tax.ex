defmodule Dhc.Stripe.PaymentPagesCheckoutSessionAutomaticTax do
  @moduledoc """
  Provides struct and type for a PaymentPagesCheckoutSessionAutomaticTax
  """

  @type t :: %__MODULE__{
          enabled: boolean,
          liability: Dhc.Stripe.ConnectAccountReference.t() | nil,
          provider: String.t() | nil,
          status: String.t() | nil
        }

  defstruct [:enabled, :liability, :provider, :status]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      enabled: :boolean,
      liability: {Dhc.Stripe.ConnectAccountReference, :t},
      provider: :string,
      status: {:enum, ["complete", "failed", "requires_location_inputs"]}
    ]
  end
end
