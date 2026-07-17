defmodule Dhc.Stripe.PaymentMethodCardPresentNetworks do
  @moduledoc """
  Provides struct and type for a PaymentMethodCardPresentNetworks
  """

  @type t :: %__MODULE__{available: [String.t()], preferred: String.t() | nil}

  defstruct [:available, :preferred]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [available: [:string], preferred: :string]
  end
end
