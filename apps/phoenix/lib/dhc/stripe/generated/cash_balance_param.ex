defmodule Dhc.Stripe.CashBalanceParam do
  @moduledoc """
  Provides struct and types for a CashBalanceParam
  """

  @type t :: %__MODULE__{settings: Dhc.Stripe.BalanceSettingsParam.t() | nil}

  defstruct [:settings]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [settings: {Dhc.Stripe.BalanceSettingsParam, :t}]
  end
end
