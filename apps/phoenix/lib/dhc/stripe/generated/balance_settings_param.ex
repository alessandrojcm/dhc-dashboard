defmodule Dhc.Stripe.BalanceSettingsParam do
  @moduledoc """
  Provides struct and types for a BalanceSettingsParam
  """

  @type t :: %__MODULE__{reconciliation_mode: String.t() | nil}

  defstruct [:reconciliation_mode]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [reconciliation_mode: {:enum, ["automatic", "manual", "merchant_default"]}]
  end
end
