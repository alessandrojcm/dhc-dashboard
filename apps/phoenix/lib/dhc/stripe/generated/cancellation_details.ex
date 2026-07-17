defmodule Dhc.Stripe.CancellationDetails do
  @moduledoc """
  Provides struct and type for a CancellationDetails
  """

  @type t :: %__MODULE__{
          comment: String.t() | nil,
          feedback: String.t() | nil,
          reason: String.t() | nil
        }

  defstruct [:comment, :feedback, :reason]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      comment: :string,
      feedback:
        {:enum,
         [
           "customer_service",
           "low_quality",
           "missing_features",
           "other",
           "switched_service",
           "too_complex",
           "too_expensive",
           "unused"
         ]},
      reason:
        {:enum,
         [
           "canceled_by_retention_policy",
           "cancellation_requested",
           "payment_disputed",
           "payment_failed"
         ]}
    ]
  end
end
