defmodule Dhc.Stripe.BillingCreditBalanceTransaction do
  @moduledoc """
  Provides struct and type for a BillingCreditBalanceTransaction
  """

  @type t :: %__MODULE__{
          created: integer,
          credit: Dhc.Stripe.BillingCreditGrantsResourceBalanceCredit.t() | nil,
          credit_grant: Dhc.Stripe.BillingCreditGrant.t() | String.t(),
          debit: Dhc.Stripe.BillingCreditGrantsResourceBalanceDebit.t() | nil,
          effective_at: integer,
          id: String.t(),
          livemode: boolean,
          object: String.t(),
          test_clock: Dhc.Stripe.TestHelpersTestClock.t() | String.t() | nil,
          type: String.t() | nil
        }

  defstruct [
    :created,
    :credit,
    :credit_grant,
    :debit,
    :effective_at,
    :id,
    :livemode,
    :object,
    :test_clock,
    :type
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      created: {:integer, "unix-time"},
      credit: {Dhc.Stripe.BillingCreditGrantsResourceBalanceCredit, :t},
      credit_grant: {:union, [:string, {Dhc.Stripe.BillingCreditGrant, :t}]},
      debit: {Dhc.Stripe.BillingCreditGrantsResourceBalanceDebit, :t},
      effective_at: {:integer, "unix-time"},
      id: :string,
      livemode: :boolean,
      object: {:const, "billing.credit_balance_transaction"},
      test_clock: {:union, [:string, {Dhc.Stripe.TestHelpersTestClock, :t}]},
      type: {:enum, ["credit", "debit"]}
    ]
  end
end
