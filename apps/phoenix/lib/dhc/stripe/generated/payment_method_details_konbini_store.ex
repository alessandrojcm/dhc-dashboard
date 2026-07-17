defmodule Dhc.Stripe.PaymentMethodDetailsKonbiniStore do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsKonbiniStore
  """

  @type t :: %__MODULE__{chain: String.t() | nil}

  defstruct [:chain]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [chain: {:enum, ["familymart", "lawson", "ministop", "seicomart"]}]
  end
end
