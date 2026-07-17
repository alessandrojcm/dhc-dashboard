defmodule Dhc.Stripe.PaymentPagesCheckoutSessionTaxIdCollection do
  @moduledoc """
  Provides struct and type for a PaymentPagesCheckoutSessionTaxIdCollection
  """

  @type t :: %__MODULE__{enabled: boolean, required: String.t()}

  defstruct [:enabled, :required]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [enabled: :boolean, required: {:enum, ["if_supported", "never"]}]
  end
end
