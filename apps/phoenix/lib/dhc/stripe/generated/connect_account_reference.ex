defmodule Dhc.Stripe.ConnectAccountReference do
  @moduledoc """
  Provides struct and type for a ConnectAccountReference
  """

  @type t :: %__MODULE__{account: Dhc.Stripe.Account.t() | String.t() | nil, type: String.t()}

  defstruct [:account, :type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [account: {:union, [:string, {Dhc.Stripe.Account, :t}]}, type: {:enum, ["account", "self"]}]
  end
end
