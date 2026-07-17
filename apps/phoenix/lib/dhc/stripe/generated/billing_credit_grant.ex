defmodule Dhc.Stripe.BillingCreditGrant do
  @moduledoc """
  Provides struct and type for a BillingCreditGrant
  """

  @type t :: %__MODULE__{
          amount: Dhc.Stripe.BillingCreditGrantsResourceAmount.t(),
          applicability_config: Dhc.Stripe.BillingCreditGrantsResourceApplicabilityConfig.t(),
          category: String.t(),
          created: integer,
          customer: Dhc.Stripe.Customer.t() | Dhc.Stripe.DeletedCustomer.t() | String.t(),
          customer_account: String.t() | nil,
          effective_at: integer | nil,
          expires_at: integer | nil,
          id: String.t(),
          livemode: boolean,
          metadata: map,
          name: String.t() | nil,
          object: String.t(),
          priority: integer | nil,
          test_clock: Dhc.Stripe.TestHelpersTestClock.t() | String.t() | nil,
          updated: integer,
          voided_at: integer | nil
        }

  defstruct [
    :amount,
    :applicability_config,
    :category,
    :created,
    :customer,
    :customer_account,
    :effective_at,
    :expires_at,
    :id,
    :livemode,
    :metadata,
    :name,
    :object,
    :priority,
    :test_clock,
    :updated,
    :voided_at
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: {Dhc.Stripe.BillingCreditGrantsResourceAmount, :t},
      applicability_config: {Dhc.Stripe.BillingCreditGrantsResourceApplicabilityConfig, :t},
      category: {:enum, ["paid", "promotional"]},
      created: {:integer, "unix-time"},
      customer: {:union, [:string, {Dhc.Stripe.Customer, :t}, {Dhc.Stripe.DeletedCustomer, :t}]},
      customer_account: :string,
      effective_at: {:integer, "unix-time"},
      expires_at: {:integer, "unix-time"},
      id: :string,
      livemode: :boolean,
      metadata: :map,
      name: :string,
      object: {:const, "billing.credit_grant"},
      priority: :integer,
      test_clock: {:union, [:string, {Dhc.Stripe.TestHelpersTestClock, :t}]},
      updated: {:integer, "unix-time"},
      voided_at: {:integer, "unix-time"}
    ]
  end
end
