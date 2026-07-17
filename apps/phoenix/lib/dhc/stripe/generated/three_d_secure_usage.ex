defmodule Dhc.Stripe.ThreeDSecureUsage do
  @moduledoc """
  Provides struct and type for a ThreeDSecureUsage
  """

  @type t :: %__MODULE__{supported: boolean}

  defstruct [:supported]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [supported: :boolean]
  end
end
