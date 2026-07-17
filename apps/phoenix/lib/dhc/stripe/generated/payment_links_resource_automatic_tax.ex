defmodule Dhc.Stripe.PaymentLinksResourceAutomaticTax do
  @moduledoc """
  Provides struct and type for a PaymentLinksResourceAutomaticTax
  """

  @type t :: %__MODULE__{
          enabled: boolean,
          liability: Dhc.Stripe.ConnectAccountReference.t() | nil
        }

  defstruct [:enabled, :liability]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [enabled: :boolean, liability: {Dhc.Stripe.ConnectAccountReference, :t}]
  end
end
