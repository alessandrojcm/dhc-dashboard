defmodule Dhc.Stripe.PersonRelationship do
  @moduledoc """
  Provides struct and type for a PersonRelationship
  """

  @type t :: %__MODULE__{
          authorizer: boolean | nil,
          director: boolean | nil,
          executive: boolean | nil,
          legal_guardian: boolean | nil,
          owner: boolean | nil,
          percent_ownership: number | nil,
          representative: boolean | nil,
          title: String.t() | nil
        }

  defstruct [
    :authorizer,
    :director,
    :executive,
    :legal_guardian,
    :owner,
    :percent_ownership,
    :representative,
    :title
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      authorizer: :boolean,
      director: :boolean,
      executive: :boolean,
      legal_guardian: :boolean,
      owner: :boolean,
      percent_ownership: :number,
      representative: :boolean,
      title: :string
    ]
  end
end
