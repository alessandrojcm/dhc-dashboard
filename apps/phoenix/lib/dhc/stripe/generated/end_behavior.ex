defmodule Dhc.Stripe.EndBehavior do
  @moduledoc """
  Provides struct and types for a EndBehavior
  """

  @type t :: %__MODULE__{missing_payment_method: String.t()}

  defstruct [:missing_payment_method]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [missing_payment_method: {:enum, ["cancel", "create_invoice", "pause"]}]
  end
end
