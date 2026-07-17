defmodule Dhc.Stripe.ChargeTransferData do
  @moduledoc """
  Provides struct and type for a ChargeTransferData
  """

  @type t :: %__MODULE__{amount: integer | nil, destination: Dhc.Stripe.Account.t() | String.t()}

  defstruct [:amount, :destination]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [amount: :integer, destination: {:union, [:string, {Dhc.Stripe.Account, :t}]}]
  end
end
