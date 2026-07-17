defmodule Dhc.Stripe.CustomerBalanceCustomerBalanceSettings do
  @moduledoc """
  Provides struct and type for a CustomerBalanceCustomerBalanceSettings
  """

  @type t :: %__MODULE__{reconciliation_mode: String.t(), using_merchant_default: boolean}

  defstruct [:reconciliation_mode, :using_merchant_default]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [reconciliation_mode: {:enum, ["automatic", "manual"]}, using_merchant_default: :boolean]
  end
end
