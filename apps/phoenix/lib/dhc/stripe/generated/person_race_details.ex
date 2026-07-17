defmodule Dhc.Stripe.PersonRaceDetails do
  @moduledoc """
  Provides struct and type for a PersonRaceDetails
  """

  @type t :: %__MODULE__{race: [String.t()] | nil, race_other: String.t() | nil}

  defstruct [:race, :race_other]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      race: [
        enum: [
          "african_american",
          "american_indian_or_alaska_native",
          "asian",
          "asian_indian",
          "black_or_african_american",
          "chinese",
          "ethiopian",
          "filipino",
          "guamanian_or_chamorro",
          "haitian",
          "jamaican",
          "japanese",
          "korean",
          "native_hawaiian",
          "native_hawaiian_or_other_pacific_islander",
          "nigerian",
          "other_asian",
          "other_black_or_african_american",
          "other_pacific_islander",
          "prefer_not_to_answer",
          "samoan",
          "somali",
          "vietnamese",
          "white"
        ]
      ],
      race_other: :string
    ]
  end
end
