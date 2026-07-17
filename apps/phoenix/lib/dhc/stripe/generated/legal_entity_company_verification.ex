defmodule Dhc.Stripe.LegalEntityCompanyVerification do
  @moduledoc """
  Provides struct and type for a LegalEntityCompanyVerification
  """

  @type t :: %__MODULE__{document: Dhc.Stripe.LegalEntityCompanyVerificationDocument.t()}

  defstruct [:document]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [document: {Dhc.Stripe.LegalEntityCompanyVerificationDocument, :t}]
  end
end
