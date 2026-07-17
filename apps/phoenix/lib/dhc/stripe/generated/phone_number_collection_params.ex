defmodule Dhc.Stripe.PhoneNumberCollectionParams do
  @moduledoc """
  Provides struct and type for a PhoneNumberCollectionParams
  """

  @type t :: %__MODULE__{enabled: boolean}

  defstruct [:enabled]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [enabled: :boolean]
  end
end
