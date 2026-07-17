defmodule Dhc.Stripe.IssuingCardholderIdDocument do
  @moduledoc """
  Provides struct and type for a IssuingCardholderIdDocument
  """

  @type t :: %__MODULE__{
          back: Dhc.Stripe.File.t() | String.t() | nil,
          front: Dhc.Stripe.File.t() | String.t() | nil
        }

  defstruct [:back, :front]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      back: {:union, [:string, {Dhc.Stripe.File, :t}]},
      front: {:union, [:string, {Dhc.Stripe.File, :t}]}
    ]
  end
end
