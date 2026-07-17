defmodule Dhc.Stripe.SubscriptionTransferData do
  @moduledoc """
  Provides struct and type for a SubscriptionTransferData
  """

  @type t :: %__MODULE__{
          amount_percent: number | nil,
          destination: Dhc.Stripe.Account.t() | String.t()
        }

  defstruct [:amount_percent, :destination]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [amount_percent: :number, destination: {:union, [:string, {Dhc.Stripe.Account, :t}]}]
  end
end
