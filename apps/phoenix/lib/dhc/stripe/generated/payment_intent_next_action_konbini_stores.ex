defmodule Dhc.Stripe.PaymentIntentNextActionKonbiniStores do
  @moduledoc """
  Provides struct and type for a PaymentIntentNextActionKonbiniStores
  """

  @type t :: %__MODULE__{
          familymart: Dhc.Stripe.PaymentIntentNextActionKonbiniFamilymart.t() | nil,
          lawson: Dhc.Stripe.PaymentIntentNextActionKonbiniLawson.t() | nil,
          ministop: Dhc.Stripe.PaymentIntentNextActionKonbiniMinistop.t() | nil,
          seicomart: Dhc.Stripe.PaymentIntentNextActionKonbiniSeicomart.t() | nil
        }

  defstruct [:familymart, :lawson, :ministop, :seicomart]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      familymart: {Dhc.Stripe.PaymentIntentNextActionKonbiniFamilymart, :t},
      lawson: {Dhc.Stripe.PaymentIntentNextActionKonbiniLawson, :t},
      ministop: {Dhc.Stripe.PaymentIntentNextActionKonbiniMinistop, :t},
      seicomart: {Dhc.Stripe.PaymentIntentNextActionKonbiniSeicomart, :t}
    ]
  end
end
