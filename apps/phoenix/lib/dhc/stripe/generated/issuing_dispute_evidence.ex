defmodule Dhc.Stripe.IssuingDisputeEvidence do
  @moduledoc """
  Provides struct and type for a IssuingDisputeEvidence
  """

  @type t :: %__MODULE__{
          canceled: Dhc.Stripe.IssuingDisputeCanceledEvidence.t() | nil,
          duplicate: Dhc.Stripe.IssuingDisputeDuplicateEvidence.t() | nil,
          fraudulent: Dhc.Stripe.IssuingDisputeFraudulentEvidence.t() | nil,
          merchandise_not_as_described:
            Dhc.Stripe.IssuingDisputeMerchandiseNotAsDescribedEvidence.t() | nil,
          no_valid_authorization: Dhc.Stripe.IssuingDisputeNoValidAuthorizationEvidence.t() | nil,
          not_received: Dhc.Stripe.IssuingDisputeNotReceivedEvidence.t() | nil,
          other: Dhc.Stripe.IssuingDisputeOtherEvidence.t() | nil,
          reason: String.t(),
          service_not_as_described:
            Dhc.Stripe.IssuingDisputeServiceNotAsDescribedEvidence.t() | nil
        }

  defstruct [
    :canceled,
    :duplicate,
    :fraudulent,
    :merchandise_not_as_described,
    :no_valid_authorization,
    :not_received,
    :other,
    :reason,
    :service_not_as_described
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      canceled: {Dhc.Stripe.IssuingDisputeCanceledEvidence, :t},
      duplicate: {Dhc.Stripe.IssuingDisputeDuplicateEvidence, :t},
      fraudulent: {Dhc.Stripe.IssuingDisputeFraudulentEvidence, :t},
      merchandise_not_as_described:
        {Dhc.Stripe.IssuingDisputeMerchandiseNotAsDescribedEvidence, :t},
      no_valid_authorization: {Dhc.Stripe.IssuingDisputeNoValidAuthorizationEvidence, :t},
      not_received: {Dhc.Stripe.IssuingDisputeNotReceivedEvidence, :t},
      other: {Dhc.Stripe.IssuingDisputeOtherEvidence, :t},
      reason:
        {:enum,
         [
           "canceled",
           "duplicate",
           "fraudulent",
           "merchandise_not_as_described",
           "no_valid_authorization",
           "not_received",
           "other",
           "service_not_as_described"
         ]},
      service_not_as_described: {Dhc.Stripe.IssuingDisputeServiceNotAsDescribedEvidence, :t}
    ]
  end
end
