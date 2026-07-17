defmodule Dhc.Stripe.Customer do
  @moduledoc """
  Provides struct and type for a Customer
  """

  @type t :: %__MODULE__{
          address: Dhc.Stripe.Address.t() | nil,
          balance: integer | nil,
          business_name: String.t() | nil,
          cash_balance: Dhc.Stripe.CashBalance.t() | nil,
          created: integer,
          currency: String.t() | nil,
          customer_account: String.t() | nil,
          default_source:
            Dhc.Stripe.BankAccount.t()
            | Dhc.Stripe.Card.t()
            | Dhc.Stripe.Source.t()
            | String.t()
            | nil,
          delinquent: boolean | nil,
          description: String.t() | nil,
          discount: Dhc.Stripe.Discount.t() | nil,
          email: String.t() | nil,
          id: String.t(),
          individual_name: String.t() | nil,
          invoice_credit_balance: map | nil,
          invoice_prefix: String.t() | nil,
          invoice_settings: Dhc.Stripe.InvoiceSettingCustomerSetting.t() | nil,
          livemode: boolean,
          metadata: map | nil,
          name: String.t() | nil,
          next_invoice_sequence: integer | nil,
          object: String.t(),
          phone: String.t() | nil,
          preferred_locales: [String.t()] | nil,
          shipping: Dhc.Stripe.Shipping.t() | nil,
          sources: Dhc.Stripe.ApmsSourcesSourceList.t() | nil,
          subscriptions: Dhc.Stripe.SubscriptionList.t() | nil,
          tax: Dhc.Stripe.CustomerTax.t() | nil,
          tax_exempt: String.t() | nil,
          tax_ids: Dhc.Stripe.TaxIDsList.t() | nil,
          test_clock: Dhc.Stripe.TestHelpersTestClock.t() | String.t() | nil
        }

  defstruct [
    :address,
    :balance,
    :business_name,
    :cash_balance,
    :created,
    :currency,
    :customer_account,
    :default_source,
    :delinquent,
    :description,
    :discount,
    :email,
    :id,
    :individual_name,
    :invoice_credit_balance,
    :invoice_prefix,
    :invoice_settings,
    :livemode,
    :metadata,
    :name,
    :next_invoice_sequence,
    :object,
    :phone,
    :preferred_locales,
    :shipping,
    :sources,
    :subscriptions,
    :tax,
    :tax_exempt,
    :tax_ids,
    :test_clock
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      address: {Dhc.Stripe.Address, :t},
      balance: :integer,
      business_name: :string,
      cash_balance: {Dhc.Stripe.CashBalance, :t},
      created: {:integer, "unix-time"},
      currency: :string,
      customer_account: :string,
      default_source:
        {:union,
         [:string, {Dhc.Stripe.BankAccount, :t}, {Dhc.Stripe.Card, :t}, {Dhc.Stripe.Source, :t}]},
      delinquent: :boolean,
      description: :string,
      discount: {Dhc.Stripe.Discount, :t},
      email: :string,
      id: :string,
      individual_name: :string,
      invoice_credit_balance: :map,
      invoice_prefix: :string,
      invoice_settings: {Dhc.Stripe.InvoiceSettingCustomerSetting, :t},
      livemode: :boolean,
      metadata: :map,
      name: :string,
      next_invoice_sequence: :integer,
      object: {:const, "customer"},
      phone: :string,
      preferred_locales: [:string],
      shipping: {Dhc.Stripe.Shipping, :t},
      sources: {Dhc.Stripe.ApmsSourcesSourceList, :t},
      subscriptions: {Dhc.Stripe.SubscriptionList, :t},
      tax: {Dhc.Stripe.CustomerTax, :t},
      tax_exempt: {:enum, ["exempt", "none", "reverse"]},
      tax_ids: {Dhc.Stripe.TaxIDsList, :t},
      test_clock: {:union, [:string, {Dhc.Stripe.TestHelpersTestClock, :t}]}
    ]
  end
end
