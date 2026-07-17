defmodule Dhc.Stripe.RestrictionsParam do
  @moduledoc """
  Provides struct and type for a RestrictionsParam
  """

  @type t :: %__MODULE__{brands_blocked: [String.t()] | nil}

  defstruct [:brands_blocked]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      brands_blocked: [
        enum: ["american_express", "discover_global_network", "mastercard", "visa"]
      ]
    ]
  end
end
