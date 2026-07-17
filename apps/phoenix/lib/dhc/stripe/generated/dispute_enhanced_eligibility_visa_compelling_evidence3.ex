defmodule Dhc.Stripe.DisputeEnhancedEligibilityVisaCompellingEvidence3 do
  @moduledoc """
  Provides struct and type for a DisputeEnhancedEligibilityVisaCompellingEvidence3
  """

  @type t :: %__MODULE__{required_actions: [String.t()], status: String.t()}

  defstruct [:required_actions, :status]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      required_actions: [
        enum: [
          "missing_customer_identifiers",
          "missing_disputed_transaction_description",
          "missing_merchandise_or_services",
          "missing_prior_undisputed_transaction_description",
          "missing_prior_undisputed_transactions"
        ]
      ],
      status: {:enum, ["not_qualified", "qualified", "requires_action"]}
    ]
  end
end
