defmodule Dhc.Stripe.Error do
  @moduledoc """
  Provides struct and type for a Error
  """

  @type t :: %__MODULE__{error: Dhc.Stripe.ApiErrors.t()}

  defstruct [:error]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [error: {Dhc.Stripe.ApiErrors, :t}]
  end
end
