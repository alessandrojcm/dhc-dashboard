defmodule Dhc.Stripe.PaymentMethodDetailsAchDebit do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsAchDebit
  """

  @type t :: %__MODULE__{
          account_holder_type: String.t() | nil,
          bank_name: String.t() | nil,
          country: String.t() | nil,
          fingerprint: String.t() | nil,
          last4: String.t() | nil,
          routing_number: String.t() | nil
        }

  defstruct [:account_holder_type, :bank_name, :country, :fingerprint, :last4, :routing_number]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      account_holder_type: {:enum, ["company", "individual"]},
      bank_name: :string,
      country: :string,
      fingerprint: :string,
      last4: :string,
      routing_number: :string
    ]
  end
end
