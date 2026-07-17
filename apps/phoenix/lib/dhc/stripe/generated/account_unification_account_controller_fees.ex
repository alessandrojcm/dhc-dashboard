defmodule Dhc.Stripe.AccountUnificationAccountControllerFees do
  @moduledoc """
  Provides struct and type for a AccountUnificationAccountControllerFees
  """

  @type t :: %__MODULE__{payer: String.t()}

  defstruct [:payer]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [payer: {:enum, ["account", "application", "application_custom", "application_express"]}]
  end
end
