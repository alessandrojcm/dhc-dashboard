defmodule Dhc.Stripe.IssuingCardLifecycleConditions do
  @moduledoc """
  Provides struct and type for a IssuingCardLifecycleConditions
  """

  @type t :: %__MODULE__{payment_count: integer}

  defstruct [:payment_count]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [payment_count: :integer]
  end
end
