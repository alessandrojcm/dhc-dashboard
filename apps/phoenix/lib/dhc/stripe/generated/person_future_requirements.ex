defmodule Dhc.Stripe.PersonFutureRequirements do
  @moduledoc """
  Provides struct and type for a PersonFutureRequirements
  """

  @type t :: %__MODULE__{
          alternatives: [Dhc.Stripe.AccountRequirementsAlternative.t()] | nil,
          currently_due: [String.t()],
          errors: [Dhc.Stripe.AccountRequirementsError.t()],
          eventually_due: [String.t()],
          past_due: [String.t()],
          pending_verification: [String.t()]
        }

  defstruct [
    :alternatives,
    :currently_due,
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
      currently_due: [:string],
      errors: [{Dhc.Stripe.AccountRequirementsError, :t}],
      eventually_due: [:string],
      past_due: [:string],
      pending_verification: [:string]
    ]
  end
end
