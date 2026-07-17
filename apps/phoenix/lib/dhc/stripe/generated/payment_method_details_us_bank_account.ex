defmodule Dhc.Stripe.PaymentMethodDetailsUsBankAccount do
  @moduledoc """
  Provides struct and type for a PaymentMethodDetailsUsBankAccount
  """

  @type t :: %__MODULE__{
          account_holder_type: String.t() | nil,
          account_type: String.t() | nil,
          bank_name: String.t() | nil,
          expected_debit_date: String.t() | nil,
          fingerprint: String.t() | nil,
          last4: String.t() | nil,
          mandate: Dhc.Stripe.Mandate.t() | String.t() | nil,
          payment_reference: String.t() | nil,
          routing_number: String.t() | nil
        }

  defstruct [
    :account_holder_type,
    :account_type,
    :bank_name,
    :expected_debit_date,
    :fingerprint,
    :last4,
    :mandate,
    :payment_reference,
    :routing_number
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      account_holder_type: {:enum, ["company", "individual"]},
      account_type: {:enum, ["checking", "savings"]},
      bank_name: :string,
      expected_debit_date: :string,
      fingerprint: :string,
      last4: :string,
      mandate: {:union, [:string, {Dhc.Stripe.Mandate, :t}]},
      payment_reference: :string,
      routing_number: :string
    ]
  end
end
