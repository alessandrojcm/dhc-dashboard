defmodule Dhc.Stripe.AccountRequirements do
  @moduledoc """
  Provides struct and type for a AccountRequirements
  """

  @type t :: %__MODULE__{
          alternatives: [Dhc.Stripe.AccountRequirementsAlternative.t()] | nil,
          current_deadline: integer | nil,
          currently_due: [String.t()] | nil,
          disabled_reason: String.t() | nil,
          errors: [Dhc.Stripe.AccountRequirementsError.t()] | nil,
          eventually_due: [String.t()] | nil,
          past_due: [String.t()] | nil,
          pending_verification: [String.t()] | nil
        }

  defstruct [
    :alternatives,
    :current_deadline,
    :currently_due,
    :disabled_reason,
    :errors,
    :eventually_due,
    :past_due,
    :pending_verification
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      alternatives: [{Dhc.Stripe.AccountRequirementsAlternative, :t}],
      current_deadline: {:integer, "unix-time"},
      currently_due: [:string],
      disabled_reason:
        {:enum,
         [
           "action_required.requested_capabilities",
           "listed",
           "other",
           "platform_paused",
           "rejected.fraud",
           "rejected.incomplete_verification",
           "rejected.listed",
           "rejected.other",
           "rejected.platform_fraud",
           "rejected.platform_other",
           "rejected.platform_terms_of_service",
           "rejected.terms_of_service",
           "requirements.past_due",
           "requirements.pending_verification",
           "under_review"
         ]},
      errors: [{Dhc.Stripe.AccountRequirementsError, :t}],
      eventually_due: [:string],
      past_due: [:string],
      pending_verification: [:string]
    ]
  end
end
