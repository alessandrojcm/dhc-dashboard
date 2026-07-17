defmodule Dhc.Stripe.SourceTypeAchDebit do
  @moduledoc """
  Provides struct and type for a SourceTypeAchDebit
  """

  @type t :: %__MODULE__{
          bank_name: String.t() | nil,
          country: String.t() | nil,
          fingerprint: String.t() | nil,
          last4: String.t() | nil,
          routing_number: String.t() | nil,
          type: String.t() | nil
        }

  defstruct [:bank_name, :country, :fingerprint, :last4, :routing_number, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      bank_name: :string,
      country: :string,
      fingerprint: :string,
      last4: :string,
      routing_number: :string,
      type: :string
    ]
  end
end
