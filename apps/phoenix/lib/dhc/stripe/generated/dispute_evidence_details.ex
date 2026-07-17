defmodule Dhc.Stripe.DisputeEvidenceDetails do
  @moduledoc """
  Provides struct and type for a DisputeEvidenceDetails
  """

  @type t :: %__MODULE__{
          due_by: integer | nil,
          enhanced_eligibility: Dhc.Stripe.DisputeEnhancedEligibility.t(),
          has_evidence: boolean,
          past_due: boolean,
          submission_count: integer
        }

  defstruct [:due_by, :enhanced_eligibility, :has_evidence, :past_due, :submission_count]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      due_by: {:integer, "unix-time"},
      enhanced_eligibility: {Dhc.Stripe.DisputeEnhancedEligibility, :t},
      has_evidence: :boolean,
      past_due: :boolean,
      submission_count: :integer
    ]
  end
end
