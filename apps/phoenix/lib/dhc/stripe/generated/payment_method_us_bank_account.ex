defmodule Dhc.Stripe.PaymentMethodUsBankAccount do
  @moduledoc """
  Provides struct and type for a PaymentMethodUsBankAccount
  """

  @type t :: %__MODULE__{
          account_holder_type: String.t() | nil,
          account_type: String.t() | nil,
          bank_name: String.t() | nil,
          financial_connections_account: String.t() | nil,
          fingerprint: String.t() | nil,
          last4: String.t() | nil,
          networks: Dhc.Stripe.UsBankAccountNetworks.t() | nil,
          routing_number: String.t() | nil,
          status_details: Dhc.Stripe.PaymentMethodUsBankAccountStatusDetails.t() | nil
        }

  defstruct [
    :account_holder_type,
    :account_type,
    :bank_name,
    :financial_connections_account,
    :fingerprint,
    :last4,
    :networks,
    :routing_number,
    :status_details
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      account_holder_type: {:enum, ["company", "individual"]},
      account_type: {:enum, ["checking", "savings"]},
      bank_name: :string,
      financial_connections_account: :string,
      fingerprint: :string,
      last4: :string,
      networks: {Dhc.Stripe.UsBankAccountNetworks, :t},
      routing_number: :string,
      status_details: {Dhc.Stripe.PaymentMethodUsBankAccountStatusDetails, :t}
    ]
  end
end
