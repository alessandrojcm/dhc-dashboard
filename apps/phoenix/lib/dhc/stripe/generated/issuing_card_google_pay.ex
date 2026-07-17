defmodule Dhc.Stripe.IssuingCardGooglePay do
  @moduledoc """
  Provides struct and type for a IssuingCardGooglePay
  """

  @type t :: %__MODULE__{eligible: boolean, ineligible_reason: String.t() | nil}

  defstruct [:eligible, :ineligible_reason]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      eligible: :boolean,
      ineligible_reason:
        {:enum, ["missing_agreement", "missing_cardholder_contact", "unsupported_region"]}
    ]
  end
end
