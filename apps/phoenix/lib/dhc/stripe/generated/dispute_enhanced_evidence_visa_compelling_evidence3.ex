defmodule Dhc.Stripe.DisputeEnhancedEvidenceVisaCompellingEvidence3 do
  @moduledoc """
  Provides struct and type for a DisputeEnhancedEvidenceVisaCompellingEvidence3
  """

  @type t :: %__MODULE__{
          disputed_transaction:
            Dhc.Stripe.DisputeVisaCompellingEvidence3DisputedTransaction.t() | nil,
          prior_undisputed_transactions: [
            Dhc.Stripe.DisputeVisaCompellingEvidence3PriorUndisputedTransaction.t()
          ]
        }

  defstruct [:disputed_transaction, :prior_undisputed_transactions]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      disputed_transaction: {Dhc.Stripe.DisputeVisaCompellingEvidence3DisputedTransaction, :t},
      prior_undisputed_transactions: [
        {Dhc.Stripe.DisputeVisaCompellingEvidence3PriorUndisputedTransaction, :t}
      ]
    ]
  end
end
