defmodule Dhc.Stripe.PersonUsCfpbData do
  @moduledoc """
  Provides struct and type for a PersonUsCfpbData
  """

  @type t :: %__MODULE__{
          ethnicity_details: Dhc.Stripe.PersonEthnicityDetails.t() | nil,
          race_details: Dhc.Stripe.PersonRaceDetails.t() | nil,
          self_identified_gender: String.t() | nil
        }

  defstruct [:ethnicity_details, :race_details, :self_identified_gender]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      ethnicity_details: {Dhc.Stripe.PersonEthnicityDetails, :t},
      race_details: {Dhc.Stripe.PersonRaceDetails, :t},
      self_identified_gender: :string
    ]
  end
end
