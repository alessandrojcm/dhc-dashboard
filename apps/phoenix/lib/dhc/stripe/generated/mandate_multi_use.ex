defmodule Dhc.Stripe.MandateMultiUse do
  @moduledoc """
  Provides struct and type for a MandateMultiUse
  """

  @type t :: %__MODULE__{amount: integer | nil, currency: String.t() | nil}

  defstruct [:amount, :currency]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [amount: :integer, currency: {:string, "currency"}]
  end
end
