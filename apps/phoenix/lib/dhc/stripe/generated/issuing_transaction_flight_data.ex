defmodule Dhc.Stripe.IssuingTransactionFlightData do
  @moduledoc """
  Provides struct and type for a IssuingTransactionFlightData
  """

  @type t :: %__MODULE__{
          departure_at: integer | nil,
          passenger_name: String.t() | nil,
          refundable: boolean | nil,
          segments: [Dhc.Stripe.IssuingTransactionFlightDataLeg.t()] | nil,
          travel_agency: String.t() | nil
        }

  defstruct [:departure_at, :passenger_name, :refundable, :segments, :travel_agency]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      departure_at: :integer,
      passenger_name: :string,
      refundable: :boolean,
      segments: [{Dhc.Stripe.IssuingTransactionFlightDataLeg, :t}],
      travel_agency: :string
    ]
  end
end
