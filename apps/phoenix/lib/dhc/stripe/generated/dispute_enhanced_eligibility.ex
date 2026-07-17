defmodule Dhc.Stripe.DisputeEnhancedEligibility do
  @moduledoc """
  Provides struct and type for a DisputeEnhancedEligibility
  """

  @type t :: %__MODULE__{
          mastercard_compliance:
            Dhc.Stripe.DisputeEnhancedEligibilityMastercardCompliance.t() | nil,
          visa_compelling_evidence_3:
            Dhc.Stripe.DisputeEnhancedEligibilityVisaCompellingEvidence3.t() | nil,
          visa_compliance: Dhc.Stripe.DisputeEnhancedEligibilityVisaCompliance.t() | nil
        }

  defstruct [:mastercard_compliance, :visa_compelling_evidence_3, :visa_compliance]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      mastercard_compliance: {Dhc.Stripe.DisputeEnhancedEligibilityMastercardCompliance, :t},
      visa_compelling_evidence_3:
        {Dhc.Stripe.DisputeEnhancedEligibilityVisaCompellingEvidence3, :t},
      visa_compliance: {Dhc.Stripe.DisputeEnhancedEligibilityVisaCompliance, :t}
    ]
  end
end
