defmodule Dhc.Stripe.ExternalAccountRequirements do
  @moduledoc """
  Provides struct and type for a ExternalAccountRequirements
  """

  @type t :: %__MODULE__{
          currently_due: [String.t()] | nil,
          errors: [Dhc.Stripe.AccountRequirementsError.t()] | nil,
          past_due: [String.t()] | nil,
          pending_verification: [String.t()] | nil
        }

  defstruct [:currently_due, :errors, :past_due, :pending_verification]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      currently_due: [:string],
      errors: [{Dhc.Stripe.AccountRequirementsError, :t}],
      past_due: [:string],
      pending_verification: [:string]
    ]
  end
end
