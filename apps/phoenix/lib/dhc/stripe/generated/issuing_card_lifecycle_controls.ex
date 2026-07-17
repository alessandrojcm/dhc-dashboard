defmodule Dhc.Stripe.IssuingCardLifecycleControls do
  @moduledoc """
  Provides struct and type for a IssuingCardLifecycleControls
  """

  @type t :: %__MODULE__{cancel_after: Dhc.Stripe.IssuingCardLifecycleConditions.t()}

  defstruct [:cancel_after]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [cancel_after: {Dhc.Stripe.IssuingCardLifecycleConditions, :t}]
  end
end
