defmodule Dhc.Stripe.IssuingTransactionFlightDataLeg do
  @moduledoc """
  Provides struct and type for a IssuingTransactionFlightDataLeg
  """

  @type t :: %__MODULE__{
          arrival_airport_code: String.t() | nil,
          carrier: String.t() | nil,
          departure_airport_code: String.t() | nil,
          flight_number: String.t() | nil,
          service_class: String.t() | nil,
          stopover_allowed: boolean | nil
        }

  defstruct [
    :arrival_airport_code,
    :carrier,
    :departure_airport_code,
    :flight_number,
    :service_class,
    :stopover_allowed
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      arrival_airport_code: :string,
      carrier: :string,
      departure_airport_code: :string,
      flight_number: :string,
      service_class: :string,
      stopover_allowed: :boolean
    ]
  end
end
