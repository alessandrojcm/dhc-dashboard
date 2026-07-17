defmodule Dhc.Stripe.Discount do
  @moduledoc """
  Provides struct and type for a Discount
  """

  @type t :: %__MODULE__{
          checkout_session: String.t() | nil,
          customer: Dhc.Stripe.Customer.t() | Dhc.Stripe.DeletedCustomer.t() | String.t() | nil,
          customer_account: String.t() | nil,
          end: integer | nil,
          id: String.t(),
          invoice: String.t() | nil,
          invoice_item: String.t() | nil,
          object: String.t(),
          promotion_code: Dhc.Stripe.PromotionCode.t() | String.t() | nil,
          source: Dhc.Stripe.DiscountSource.t(),
          start: integer,
          subscription: String.t() | nil,
          subscription_item: String.t() | nil
        }

  defstruct [
    :checkout_session,
    :customer,
    :customer_account,
    :end,
    :id,
    :invoice,
    :invoice_item,
    :object,
    :promotion_code,
    :source,
    :start,
    :subscription,
    :subscription_item
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      checkout_session: :string,
      customer: {:union, [:string, {Dhc.Stripe.Customer, :t}, {Dhc.Stripe.DeletedCustomer, :t}]},
      customer_account: :string,
      end: {:integer, "unix-time"},
      id: :string,
      invoice: :string,
      invoice_item: :string,
      object: {:const, "discount"},
      promotion_code: {:union, [:string, {Dhc.Stripe.PromotionCode, :t}]},
      source: {Dhc.Stripe.DiscountSource, :t},
      start: {:integer, "unix-time"},
      subscription: :string,
      subscription_item: :string
    ]
  end
end
