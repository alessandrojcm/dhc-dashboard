defmodule Dhc.Stripe.PaymentMethodDetailsLink do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsLink
  """

  @type t :: %__MODULE__{country: String.t() | nil}

  defstruct [:country]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [country: :string]
  end
end
