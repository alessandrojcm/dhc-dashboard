defmodule Dhc.Stripe.PaymentMethodDataParam do
  @moduledoc """
  Provides struct and type for a PaymentMethodDataParam
  """

  @type t :: %__MODULE__{allow_redisplay: String.t() | nil}

  defstruct [:allow_redisplay]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [allow_redisplay: {:enum, ["always", "limited", "unspecified"]}]
  end
end
