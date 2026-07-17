defmodule Dhc.Stripe.IssuingCardholderIndividual do
  @moduledoc """
  Provides struct and type for a IssuingCardholderIndividual
  """

  @type t :: %__MODULE__{
          card_issuing: Dhc.Stripe.IssuingCardholderCardIssuing.t() | nil,
          dob: Dhc.Stripe.IssuingCardholderIndividualDob.t() | nil,
          first_name: String.t() | nil,
          last_name: String.t() | nil,
          verification: Dhc.Stripe.IssuingCardholderVerification.t() | nil
        }

  defstruct [:card_issuing, :dob, :first_name, :last_name, :verification]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      card_issuing: {Dhc.Stripe.IssuingCardholderCardIssuing, :t},
      dob: {Dhc.Stripe.IssuingCardholderIndividualDob, :t},
      first_name: :string,
      last_name: :string,
      verification: {Dhc.Stripe.IssuingCardholderVerification, :t}
    ]
  end
end
