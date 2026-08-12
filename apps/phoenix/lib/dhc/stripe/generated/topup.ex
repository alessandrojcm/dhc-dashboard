defmodule Dhc.Stripe.Topup do
  @moduledoc """
  Provides struct and type for a Topup
  """

  @type t :: %__MODULE__{
          amount: integer,
          balance_transaction: Dhc.Stripe.BalanceTransaction.t() | String.t() | nil,
          created: integer,
          currency: String.t(),
          description: String.t() | nil,
          expected_availability_date: integer | nil,
          failure_code: String.t() | nil,
          failure_message: String.t() | nil,
          id: String.t(),
          initiated_by: String.t() | nil,
          livemode: boolean,
          metadata: map,
          object: String.t(),
          payment_method: Dhc.Stripe.PaymentMethod.t() | String.t() | nil,
          payment_method_options: Dhc.Stripe.TopupResourcePaymentMethodOptions.t() | nil,
          source: Dhc.Stripe.Source.t() | nil,
          statement_descriptor: String.t() | nil,
          status: String.t(),
          transfer_group: String.t() | nil
        }

  defstruct [
    :amount,
    :balance_transaction,
    :created,
    :currency,
    :description,
    :expected_availability_date,
    :failure_code,
    :failure_message,
    :id,
    :initiated_by,
    :livemode,
    :metadata,
    :object,
    :payment_method,
    :payment_method_options,
    :source,
    :statement_descriptor,
    :status,
    :transfer_group
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      balance_transaction: {:union, [:string, {Dhc.Stripe.BalanceTransaction, :t}]},
      created: {:integer, "unix-time"},
      currency: :string,
      description: :string,
      expected_availability_date: :integer,
      failure_code: :string,
      failure_message: :string,
      id: :string,
      initiated_by: {:enum, ["stripe", "user"]},
      livemode: :boolean,
      metadata: :map,
      object: {:const, "topup"},
      payment_method: {:union, [:string, {Dhc.Stripe.PaymentMethod, :t}]},
      payment_method_options: {Dhc.Stripe.TopupResourcePaymentMethodOptions, :t},
      source: {Dhc.Stripe.Source, :t},
      statement_descriptor: :string,
      status: {:enum, ["canceled", "failed", "pending", "reversed", "succeeded"]},
      transfer_group: :string
    ]
  end
end
