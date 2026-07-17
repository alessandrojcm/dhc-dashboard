defmodule Dhc.Stripe.ConnectCollectionTransfer do
  @moduledoc """
  Provides struct and type for a ConnectCollectionTransfer
  """

  @type t :: %__MODULE__{
          amount: integer,
          currency: String.t(),
          destination: Dhc.Stripe.Account.t() | String.t(),
          id: String.t(),
          livemode: boolean,
          object: String.t()
        }

  defstruct [:amount, :currency, :destination, :id, :livemode, :object]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      currency: {:string, "currency"},
      destination: {:union, [:string, {Dhc.Stripe.Account, :t}]},
      id: :string,
      livemode: :boolean,
      object: {:const, "connect_collection_transfer"}
    ]
  end
end
