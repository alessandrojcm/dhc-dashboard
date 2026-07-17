defmodule Dhc.Stripe.TaxIDsOwner do
  @moduledoc """
  Provides struct and type for a TaxIDsOwner
  """

  @type t :: %__MODULE__{
          account: Dhc.Stripe.Account.t() | String.t() | nil,
          application: Dhc.Stripe.Application.t() | String.t() | nil,
          customer: Dhc.Stripe.Customer.t() | String.t() | nil,
          customer_account: String.t() | nil,
          type: String.t()
        }

  defstruct [:account, :application, :customer, :customer_account, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      account: {:union, [:string, {Dhc.Stripe.Account, :t}]},
      application: {:union, [:string, {Dhc.Stripe.Application, :t}]},
      customer: {:union, [:string, {Dhc.Stripe.Customer, :t}]},
      customer_account: :string,
      type: {:enum, ["account", "application", "customer", "self"]}
    ]
  end
end
