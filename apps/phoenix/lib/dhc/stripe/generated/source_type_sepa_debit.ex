defmodule Dhc.Stripe.SourceTypeSepaDebit do
  @moduledoc """
  Provides struct and type for a SourceTypeSepaDebit
  """

  @type t :: %__MODULE__{
          bank_code: String.t() | nil,
          branch_code: String.t() | nil,
          country: String.t() | nil,
          fingerprint: String.t() | nil,
          last4: String.t() | nil,
          mandate_reference: String.t() | nil,
          mandate_url: String.t() | nil
        }

  defstruct [
    :bank_code,
    :branch_code,
    :country,
    :fingerprint,
    :last4,
    :mandate_reference,
    :mandate_url
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      bank_code: :string,
      branch_code: :string,
      country: :string,
      fingerprint: :string,
      last4: :string,
      mandate_reference: :string,
      mandate_url: :string
    ]
  end
end
