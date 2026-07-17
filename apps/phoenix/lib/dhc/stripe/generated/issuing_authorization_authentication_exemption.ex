defmodule Dhc.Stripe.IssuingAuthorizationAuthenticationExemption do
  @moduledoc """
  Provides struct and type for a IssuingAuthorizationAuthenticationExemption
  """

  @type t :: %__MODULE__{claimed_by: String.t(), type: String.t()}

  defstruct [:claimed_by, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      claimed_by: {:enum, ["acquirer", "issuer"]},
      type: {:enum, ["low_value_transaction", "transaction_risk_analysis", "unknown"]}
    ]
  end
end
