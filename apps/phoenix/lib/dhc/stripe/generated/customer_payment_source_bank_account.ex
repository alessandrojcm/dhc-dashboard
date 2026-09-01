defmodule Dhc.Stripe.CustomerPaymentSourceBankAccount do
  @moduledoc """
  Provides struct and type for a CustomerPaymentSourceBankAccount
  """

  @type t :: %__MODULE__{
          account_holder_name: String.t() | nil,
          account_holder_type: String.t() | nil,
          account_number: String.t(),
          country: String.t(),
          currency: String.t() | nil,
          object: String.t() | nil,
          routing_number: String.t() | nil
        }

  defstruct [
    :account_holder_name,
    :account_holder_type,
    :account_number,
    :country,
    :currency,
    :object,
    :routing_number
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      account_holder_name: :string,
      account_holder_type: {:enum, ["company", "individual"]},
      account_number: :string,
      country: :string,
      currency: {:string, "currency"},
      object: {:const, "bank_account"},
      routing_number: :string
    ]
  end
end
