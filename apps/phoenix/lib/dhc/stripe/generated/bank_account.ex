defmodule Dhc.Stripe.BankAccount do
  @moduledoc """
  Provides struct and type for a BankAccount
  """

  @type t :: %__MODULE__{
          account: Dhc.Stripe.Account.t() | String.t() | nil,
          account_holder_name: String.t() | nil,
          account_holder_type: String.t() | nil,
          account_type: String.t() | nil,
          available_payout_methods: [String.t()] | nil,
          bank_name: String.t() | nil,
          country: String.t(),
          currency: String.t(),
          customer: Dhc.Stripe.Customer.t() | Dhc.Stripe.DeletedCustomer.t() | String.t() | nil,
          default_for_currency: boolean | nil,
          fingerprint: String.t() | nil,
          future_requirements: Dhc.Stripe.ExternalAccountRequirements.t() | nil,
          id: String.t(),
          last4: String.t(),
          metadata: map | nil,
          object: String.t(),
          requirements: Dhc.Stripe.ExternalAccountRequirements.t() | nil,
          routing_number: String.t() | nil,
          status: String.t()
        }

  defstruct [
    :account,
    :account_holder_name,
    :account_holder_type,
    :account_type,
    :available_payout_methods,
    :bank_name,
    :country,
    :currency,
    :customer,
    :default_for_currency,
    :fingerprint,
    :future_requirements,
    :id,
    :last4,
    :metadata,
    :object,
    :requirements,
    :routing_number,
    :status
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      account: {:union, [:string, {Dhc.Stripe.Account, :t}]},
      account_holder_name: :string,
      account_holder_type: :string,
      account_type: :string,
      available_payout_methods: [enum: ["instant", "standard"]],
      bank_name: :string,
      country: :string,
      currency: {:string, "currency"},
      customer: {:union, [:string, {Dhc.Stripe.Customer, :t}, {Dhc.Stripe.DeletedCustomer, :t}]},
      default_for_currency: :boolean,
      fingerprint: :string,
      future_requirements: {Dhc.Stripe.ExternalAccountRequirements, :t},
      id: :string,
      last4: :string,
      metadata: :map,
      object: {:const, "bank_account"},
      requirements: {Dhc.Stripe.ExternalAccountRequirements, :t},
      routing_number: :string,
      status: :string
    ]
  end
end
