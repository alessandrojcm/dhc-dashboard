defmodule Dhc.Stripe.LegalEntityPersonVerification do
  @moduledoc """
  Provides struct and type for a LegalEntityPersonVerification
  """

  @type t :: %__MODULE__{
          additional_document: Dhc.Stripe.LegalEntityPersonVerificationDocument.t() | nil,
          details: String.t() | nil,
          details_code: String.t() | nil,
          document: Dhc.Stripe.LegalEntityPersonVerificationDocument.t() | nil,
          status: String.t()
        }

  defstruct [:additional_document, :details, :details_code, :document, :status]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      additional_document: {Dhc.Stripe.LegalEntityPersonVerificationDocument, :t},
      details: :string,
      details_code: :string,
      document: {Dhc.Stripe.LegalEntityPersonVerificationDocument, :t},
      status: :string
    ]
  end
end
