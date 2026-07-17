defmodule Dhc.Stripe.IssuingCardholderRequirements do
  @moduledoc """
  Provides struct and type for a IssuingCardholderRequirements
  """

  @type t :: %__MODULE__{disabled_reason: String.t() | nil, past_due: [String.t()] | nil}

  defstruct [:disabled_reason, :past_due]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      disabled_reason:
        {:enum, ["listed", "rejected.listed", "requirements.past_due", "under_review"]},
      past_due: [
        enum: [
          "company.tax_id",
          "individual.card_issuing.user_terms_acceptance.date",
          "individual.card_issuing.user_terms_acceptance.ip",
          "individual.dob.day",
          "individual.dob.month",
          "individual.dob.year",
          "individual.first_name",
          "individual.last_name",
          "individual.verification.document"
        ]
      ]
    ]
  end
end
