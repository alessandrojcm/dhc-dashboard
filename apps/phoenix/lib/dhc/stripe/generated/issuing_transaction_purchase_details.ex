defmodule Dhc.Stripe.IssuingTransactionPurchaseDetails do
  @moduledoc """
  Provides struct and type for a IssuingTransactionPurchaseDetails
  """

  @type t :: %__MODULE__{
          fleet: Dhc.Stripe.IssuingTransactionFleetData.t() | nil,
          flight: Dhc.Stripe.IssuingTransactionFlightData.t() | nil,
          fuel: Dhc.Stripe.IssuingTransactionFuelData.t() | nil,
          lodging: Dhc.Stripe.IssuingTransactionLodgingData.t() | nil,
          receipt: [Dhc.Stripe.IssuingTransactionReceiptData.t()] | nil,
          reference: String.t() | nil
        }

  defstruct [:fleet, :flight, :fuel, :lodging, :receipt, :reference]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      fleet: {Dhc.Stripe.IssuingTransactionFleetData, :t},
      flight: {Dhc.Stripe.IssuingTransactionFlightData, :t},
      fuel: {Dhc.Stripe.IssuingTransactionFuelData, :t},
      lodging: {Dhc.Stripe.IssuingTransactionLodgingData, :t},
      receipt: [{Dhc.Stripe.IssuingTransactionReceiptData, :t}],
      reference: :string
    ]
  end
end
