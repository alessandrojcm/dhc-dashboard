defmodule Dhc.Stripe.FlowDataSubscriptionUpdateParam do
  @moduledoc """
  Provides struct and type for a FlowDataSubscriptionUpdateParam
  """

  @type t :: %__MODULE__{subscription: String.t()}

  defstruct [:subscription]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [subscription: :string]
  end
end
