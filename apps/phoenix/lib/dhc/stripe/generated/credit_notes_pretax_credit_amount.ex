defmodule Dhc.Stripe.CreditNotesPretaxCreditAmount do
  @moduledoc """
  Provides struct and type for a CreditNotesPretaxCreditAmount
  """

  @type t :: %__MODULE__{
          amount: integer,
          credit_balance_transaction:
            Dhc.Stripe.BillingCreditBalanceTransaction.t() | String.t() | nil,
          discount: Dhc.Stripe.DeletedDiscount.t() | Dhc.Stripe.Discount.t() | String.t() | nil,
          type: String.t()
        }

  defstruct [:amount, :credit_balance_transaction, :discount, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      credit_balance_transaction:
        {:union, [:string, {Dhc.Stripe.BillingCreditBalanceTransaction, :t}]},
      discount: {:union, [:string, {Dhc.Stripe.DeletedDiscount, :t}, {Dhc.Stripe.Discount, :t}]},
      type: {:enum, ["credit_balance_transaction", "discount"]}
    ]
  end
end
