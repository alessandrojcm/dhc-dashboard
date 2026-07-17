defmodule Dhc.Stripe.CheckoutPaymentMethodOptionsMandateOptionsSepaDebit do
  @moduledoc """
  Provides struct and type for a CheckoutPaymentMethodOptionsMandateOptionsSepaDebit
  """

  @type t :: %__MODULE__{reference_prefix: String.t() | nil}

  defstruct [:reference_prefix]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [reference_prefix: :string]
  end
end
