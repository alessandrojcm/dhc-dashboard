defmodule Dhc.Stripe.PersonEthnicityDetails do
  @moduledoc """
  Provides struct and type for a PersonEthnicityDetails
  """

  @type t :: %__MODULE__{ethnicity: [String.t()] | nil, ethnicity_other: String.t() | nil}

  defstruct [:ethnicity, :ethnicity_other]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      ethnicity: [
        enum: [
          "cuban",
          "hispanic_or_latino",
          "mexican",
          "not_hispanic_or_latino",
          "other_hispanic_or_latino",
          "prefer_not_to_answer",
          "puerto_rican"
        ]
      ],
      ethnicity_other: :string
    ]
  end
end
