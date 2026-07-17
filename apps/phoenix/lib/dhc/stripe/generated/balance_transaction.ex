defmodule Dhc.Stripe.BalanceTransaction do
  @moduledoc """
  Provides struct and type for a BalanceTransaction
  """

  @type t :: %__MODULE__{
          amount: integer,
          available_on: integer,
          balance_type: String.t(),
          created: integer,
          currency: String.t(),
          description: String.t() | nil,
          exchange_rate: number | nil,
          fee: integer,
          fee_details: [Dhc.Stripe.Fee.t()],
          id: String.t(),
          net: integer,
          object: String.t(),
          reporting_category: String.t(),
          source:
            Dhc.Stripe.ApplicationFee.t()
            | Dhc.Stripe.Charge.t()
            | Dhc.Stripe.ConnectCollectionTransfer.t()
            | Dhc.Stripe.CustomerCashBalanceTransaction.t()
            | Dhc.Stripe.Dispute.t()
            | Dhc.Stripe.FeeRefund.t()
            | Dhc.Stripe.IssuingAuthorization.t()
            | Dhc.Stripe.IssuingDispute.t()
            | Dhc.Stripe.IssuingTransaction.t()
            | Dhc.Stripe.Payout.t()
            | Dhc.Stripe.Refund.t()
            | Dhc.Stripe.ReserveTransaction.t()
            | Dhc.Stripe.TaxDeductedAtSource.t()
            | Dhc.Stripe.Topup.t()
            | Dhc.Stripe.Transfer.t()
            | Dhc.Stripe.TransferReversal.t()
            | String.t()
            | nil,
          status: String.t(),
          type: String.t()
        }

  defstruct [
    :amount,
    :available_on,
    :balance_type,
    :created,
    :currency,
    :description,
    :exchange_rate,
    :fee,
    :fee_details,
    :id,
    :net,
    :object,
    :reporting_category,
    :source,
    :status,
    :type
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      available_on: {:integer, "unix-time"},
      balance_type:
        {:enum, ["issuing", "payments", "refund_and_dispute_prefunding", "risk_reserved"]},
      created: {:integer, "unix-time"},
      currency: {:string, "currency"},
      description: :string,
      exchange_rate: :number,
      fee: :integer,
      fee_details: [{Dhc.Stripe.Fee, :t}],
      id: :string,
      net: :integer,
      object: {:const, "balance_transaction"},
      reporting_category: :string,
      source:
        {:union,
         [
           :string,
           {Dhc.Stripe.ApplicationFee, :t},
           {Dhc.Stripe.Charge, :t},
           {Dhc.Stripe.ConnectCollectionTransfer, :t},
           {Dhc.Stripe.CustomerCashBalanceTransaction, :t},
           {Dhc.Stripe.Dispute, :t},
           {Dhc.Stripe.FeeRefund, :t},
           {Dhc.Stripe.IssuingAuthorization, :t},
           {Dhc.Stripe.IssuingDispute, :t},
           {Dhc.Stripe.IssuingTransaction, :t},
           {Dhc.Stripe.Payout, :t},
           {Dhc.Stripe.Refund, :t},
           {Dhc.Stripe.ReserveTransaction, :t},
           {Dhc.Stripe.TaxDeductedAtSource, :t},
           {Dhc.Stripe.Topup, :t},
           {Dhc.Stripe.Transfer, :t},
           {Dhc.Stripe.TransferReversal, :t}
         ]},
      status: :string,
      type:
        {:enum,
         [
           "adjustment",
           "advance",
           "advance_funding",
           "anticipation_repayment",
           "application_fee",
           "application_fee_refund",
           "charge",
           "climate_order_purchase",
           "climate_order_refund",
           "connect_collection_transfer",
           "contribution",
           "fee_credit_funding",
           "inbound_transfer",
           "inbound_transfer_reversal",
           "issuing_authorization_hold",
           "issuing_authorization_release",
           "issuing_dispute",
           "issuing_transaction",
           "obligation_outbound",
           "obligation_reversal_inbound",
           "payment",
           "payment_failure_refund",
           "payment_network_reserve_hold",
           "payment_network_reserve_release",
           "payment_refund",
           "payment_reversal",
           "payment_unreconciled",
           "payout",
           "payout_cancel",
           "payout_failure",
           "payout_minimum_balance_hold",
           "payout_minimum_balance_release",
           "refund",
           "refund_failure",
           "reserve_hold",
           "reserve_release",
           "reserve_transaction",
           "reserved_funds",
           "stripe_balance_payment_debit",
           "stripe_balance_payment_debit_reversal",
           "stripe_fee",
           "stripe_fx_fee",
           "tax_fee",
           "tax_fund",
           "topup",
           "topup_reversal",
           "transfer",
           "transfer_cancel",
           "transfer_failure",
           "transfer_refund"
         ]}
    ]
  end
end
