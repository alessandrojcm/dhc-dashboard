defmodule Dhc.Stripe.PaymentMethodPix do
  @moduledoc """
  Provides struct and type for a PaymentMethodPix
  """

  @type t :: %__MODULE__{fingerprint: String.t() | nil}

  defstruct [:fingerprint]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [fingerprint: :string]
  end
end
