defmodule Dhc.Stripe.WalletOptionsParam do
  @moduledoc """
  Provides struct and types for a WalletOptionsParam
  """

  @type t :: %__MODULE__{display: String.t() | nil, link: Dhc.Stripe.WalletOptionsParam.t() | nil}

  defstruct [:display, :link]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [display: {:enum, ["auto", "never"]}, link: {Dhc.Stripe.WalletOptionsParam, :t}]
  end
end
