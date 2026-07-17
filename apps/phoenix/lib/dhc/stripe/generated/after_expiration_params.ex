defmodule Dhc.Stripe.AfterExpirationParams do
  @moduledoc """
  Provides struct and type for a AfterExpirationParams
  """

  @type t :: %__MODULE__{recovery: Dhc.Stripe.RecoveryParams.t() | nil}

  defstruct [:recovery]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [recovery: {Dhc.Stripe.RecoveryParams, :t}]
  end
end
