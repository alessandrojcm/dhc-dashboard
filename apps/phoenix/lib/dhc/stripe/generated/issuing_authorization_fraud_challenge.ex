defmodule Dhc.Stripe.IssuingAuthorizationFraudChallenge do
  @moduledoc """
  Provides struct and type for a IssuingAuthorizationFraudChallenge
  """

  @type t :: %__MODULE__{
          channel: String.t(),
          status: String.t(),
          undeliverable_reason: String.t() | nil
        }

  defstruct [:channel, :status, :undeliverable_reason]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      channel: {:const, "sms"},
      status: {:enum, ["expired", "pending", "rejected", "undeliverable", "verified"]},
      undeliverable_reason: {:enum, ["no_phone_number", "unsupported_phone_number"]}
    ]
  end
end
