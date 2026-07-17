defmodule Dhc.Stripe.AccountGroupMembership do
  @moduledoc """
  Provides struct and type for a AccountGroupMembership
  """

  @type t :: %__MODULE__{payments_pricing: String.t() | nil}

  defstruct [:payments_pricing]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [payments_pricing: :string]
  end
end
