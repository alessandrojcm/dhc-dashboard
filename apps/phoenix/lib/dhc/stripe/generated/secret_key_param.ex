defmodule Dhc.Stripe.SecretKeyParam do
  @moduledoc """
  Provides struct and types for a SecretKeyParam
  """

  @type t :: %__MODULE__{customer_acceptance: Dhc.Stripe.CustomerAcceptanceParam.t()}

  defstruct [:customer_acceptance]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [customer_acceptance: {Dhc.Stripe.CustomerAcceptanceParam, :t}]
  end
end
