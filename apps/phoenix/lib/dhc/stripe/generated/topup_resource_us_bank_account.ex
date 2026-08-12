defmodule Dhc.Stripe.TopupResourceUsBankAccount do
  @moduledoc """
  Provides struct and type for a TopupResourceUsBankAccount
  """

  @type t :: %__MODULE__{network: String.t()}

  defstruct [:network]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [network: {:const, "ach"}]
  end
end
