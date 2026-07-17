defmodule Dhc.Stripe.IssuingCardFraudWarning do
  @moduledoc """
  Provides struct and type for a IssuingCardFraudWarning
  """

  @type t :: %__MODULE__{started_at: integer | nil, type: String.t() | nil}

  defstruct [:started_at, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      started_at: {:integer, "unix-time"},
      type:
        {:enum,
         [
           "card_testing_exposure",
           "fraud_dispute_filed",
           "third_party_reported",
           "user_indicated_fraud"
         ]}
    ]
  end
end
