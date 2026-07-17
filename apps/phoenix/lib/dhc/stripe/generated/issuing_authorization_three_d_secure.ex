defmodule Dhc.Stripe.IssuingAuthorizationThreeDSecure do
  @moduledoc """
  Provides struct and type for a IssuingAuthorizationThreeDSecure
  """

  @type t :: %__MODULE__{result: String.t()}

  defstruct [:result]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [result: {:enum, ["attempt_acknowledged", "authenticated", "failed", "required"]}]
  end
end
