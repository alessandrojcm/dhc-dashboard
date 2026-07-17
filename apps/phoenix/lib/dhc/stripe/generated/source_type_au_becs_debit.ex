defmodule Dhc.Stripe.SourceTypeAuBecsDebit do
  @moduledoc """
  Provides struct and type for a SourceTypeAuBecsDebit
  """

  @type t :: %__MODULE__{
          bsb_number: String.t() | nil,
          fingerprint: String.t() | nil,
          last4: String.t() | nil
        }

  defstruct [:bsb_number, :fingerprint, :last4]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [bsb_number: :string, fingerprint: :string, last4: :string]
  end
end
