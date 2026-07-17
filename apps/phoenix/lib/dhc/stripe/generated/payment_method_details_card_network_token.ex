defmodule Dhc.Stripe.PaymentMethodDetailsCardNetworkToken do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsCardNetworkToken
  """

  @type t :: %__MODULE__{used: boolean}

  defstruct [:used]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [used: :boolean]
  end
end
