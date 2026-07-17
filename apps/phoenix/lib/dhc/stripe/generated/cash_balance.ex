defmodule Dhc.Stripe.CashBalance do
  @moduledoc """
  Provides struct and type for a CashBalance
  """

  @type t :: %__MODULE__{
          available: map | nil,
          customer: String.t(),
          customer_account: String.t() | nil,
          livemode: boolean,
          object: String.t(),
          settings: Dhc.Stripe.CustomerBalanceCustomerBalanceSettings.t()
        }

  defstruct [:available, :customer, :customer_account, :livemode, :object, :settings]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      available: :map,
      customer: :string,
      customer_account: :string,
      livemode: :boolean,
      object: {:const, "cash_balance"},
      settings: {Dhc.Stripe.CustomerBalanceCustomerBalanceSettings, :t}
    ]
  end
end
