defmodule Dhc.Stripe.SetupIntentPaymentMethodOptionsPaypal do
  @moduledoc """
  Provides struct and type for a SetupIntentPaymentMethodOptionsPaypal
  """

  @type t :: %__MODULE__{billing_agreement_id: String.t() | nil}

  defstruct [:billing_agreement_id]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [billing_agreement_id: :string]
  end
end
