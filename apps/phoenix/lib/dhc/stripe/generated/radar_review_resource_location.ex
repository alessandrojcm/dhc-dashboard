defmodule Dhc.Stripe.RadarReviewResourceLocation do
  @moduledoc """
  Provides struct and type for a RadarReviewResourceLocation
  """

  @type t :: %__MODULE__{
          city: String.t() | nil,
          country: String.t() | nil,
          latitude: number | nil,
          longitude: number | nil,
          region: String.t() | nil
        }

  defstruct [:city, :country, :latitude, :longitude, :region]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [city: :string, country: :string, latitude: :number, longitude: :number, region: :string]
  end
end
