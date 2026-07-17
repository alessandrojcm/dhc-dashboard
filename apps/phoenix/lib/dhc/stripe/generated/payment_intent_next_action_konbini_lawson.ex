defmodule Dhc.Stripe.PaymentIntentNextActionKonbiniLawson do
  @moduledoc """
  Provides struct and type for a PaymentIntentNextActionKonbiniLawson
  """

  @type t :: %__MODULE__{confirmation_number: String.t() | nil, payment_code: String.t()}

  defstruct [:confirmation_number, :payment_code]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [confirmation_number: :string, payment_code: :string]
  end
end
