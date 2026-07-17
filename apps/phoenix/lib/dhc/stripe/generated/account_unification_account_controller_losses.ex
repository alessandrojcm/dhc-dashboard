defmodule Dhc.Stripe.AccountUnificationAccountControllerLosses do
  @moduledoc """
  Provides struct and type for a AccountUnificationAccountControllerLosses
  """

  @type t :: %__MODULE__{payments: String.t()}

  defstruct [:payments]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [payments: {:enum, ["application", "stripe"]}]
  end
end
