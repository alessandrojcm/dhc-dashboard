defmodule Dhc.Stripe.TransferDataCreationParams do
  @moduledoc """
  Provides struct and type for a TransferDataCreationParams
  """

  @type t :: %__MODULE__{
          amount: integer | nil,
          description: String.t() | nil,
          destination: String.t(),
          metadata: map | String.t() | nil,
          payment_data: Dhc.Stripe.TransferDataPaymentDataParams.t() | nil
        }

  defstruct [:amount, :description, :destination, :metadata, :payment_data]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      amount: :integer,
      description: :string,
      destination: :string,
      metadata: {:union, [:map, const: ""]},
      payment_data: {Dhc.Stripe.TransferDataPaymentDataParams, :t}
    ]
  end
end
