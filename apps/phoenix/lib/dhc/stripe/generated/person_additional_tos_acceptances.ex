defmodule Dhc.Stripe.PersonAdditionalTosAcceptances do
  @moduledoc """
  Provides struct and type for a PersonAdditionalTosAcceptances
  """

  @type t :: %__MODULE__{account: Dhc.Stripe.PersonAdditionalTosAcceptance.t() | nil}

  defstruct [:account]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [account: {Dhc.Stripe.PersonAdditionalTosAcceptance, :t}]
  end
end
