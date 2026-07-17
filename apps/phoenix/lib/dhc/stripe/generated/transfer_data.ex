defmodule Dhc.Stripe.TransferData do
  @moduledoc """
  Provides struct and type for a TransferData
  """

  @type t :: %__MODULE__{
          amount: integer | nil,
          description: String.t() | nil,
          destination: Dhc.Stripe.Account.t() | String.t(),
          metadata: map | nil,
          payment_data: Dhc.Stripe.PaymentData.t() | nil
        }

  defstruct [:amount, :description, :destination, :metadata, :payment_data]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      description: :string,
      destination: {:union, [:string, {Dhc.Stripe.Account, :t}]},
      metadata: :map,
      payment_data: {Dhc.Stripe.PaymentData, :t}
    ]
  end
end
