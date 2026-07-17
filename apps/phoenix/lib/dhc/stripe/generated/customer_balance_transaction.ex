defmodule Dhc.Stripe.CustomerBalanceTransaction do
  @moduledoc """
  Provides struct and type for a CustomerBalanceTransaction
  """

  @type t :: %__MODULE__{
          amount: integer,
          checkout_session: Dhc.Stripe.CheckoutSession.t() | String.t() | nil,
          created: integer,
          credit_note: Dhc.Stripe.CreditNote.t() | String.t() | nil,
          currency: String.t(),
          customer: Dhc.Stripe.Customer.t() | String.t(),
          customer_account: String.t() | nil,
          description: String.t() | nil,
          ending_balance: integer,
          id: String.t(),
          invoice: Dhc.Stripe.Invoice.t() | String.t() | nil,
          livemode: boolean,
          metadata: map | nil,
          object: String.t(),
          type: String.t()
        }

  defstruct [
    :amount,
    :checkout_session,
    :created,
    :credit_note,
    :currency,
    :customer,
    :customer_account,
    :description,
    :ending_balance,
    :id,
    :invoice,
    :livemode,
    :metadata,
    :object,
    :type
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      checkout_session: {:union, [:string, {Dhc.Stripe.CheckoutSession, :t}]},
      created: {:integer, "unix-time"},
      credit_note: {:union, [:string, {Dhc.Stripe.CreditNote, :t}]},
      currency: {:string, "currency"},
      customer: {:union, [:string, {Dhc.Stripe.Customer, :t}]},
      customer_account: :string,
      description: :string,
      ending_balance: :integer,
      id: :string,
      invoice: {:union, [:string, {Dhc.Stripe.Invoice, :t}]},
      livemode: :boolean,
      metadata: :map,
      object: {:const, "customer_balance_transaction"},
      type:
        {:enum,
         [
           "adjustment",
           "applied_to_invoice",
           "checkout_session_subscription_payment",
           "checkout_session_subscription_payment_canceled",
           "credit_note",
           "initial",
           "invoice_overpaid",
           "invoice_too_large",
           "invoice_too_small",
           "migration",
           "unapplied_from_invoice",
           "unspent_receiver_credit"
         ]}
    ]
  end
end
