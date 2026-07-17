defmodule Dhc.Stripe.NameCollectionParams do
  @moduledoc """
  Provides struct and type for a NameCollectionParams
  """

  @type t :: %__MODULE__{
          business: Dhc.Stripe.NameCollectionBusinessParams.t() | nil,
          individual: Dhc.Stripe.NameCollectionIndividualParams.t() | nil
        }

  defstruct [:business, :individual]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      business: {Dhc.Stripe.NameCollectionBusinessParams, :t},
      individual: {Dhc.Stripe.NameCollectionIndividualParams, :t}
    ]
  end
end
