defmodule Dhc.Stripe.IssuingCardholderCardIssuing do
  @moduledoc """
  Provides struct and type for a IssuingCardholderCardIssuing
  """

  @type t :: %__MODULE__{
          user_terms_acceptance: Dhc.Stripe.IssuingCardholderUserTermsAcceptance.t() | nil
        }

  defstruct [:user_terms_acceptance]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [user_terms_acceptance: {Dhc.Stripe.IssuingCardholderUserTermsAcceptance, :t}]
  end
end
