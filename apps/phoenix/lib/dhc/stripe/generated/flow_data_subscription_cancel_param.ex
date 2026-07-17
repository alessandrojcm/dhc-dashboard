defmodule Dhc.Stripe.FlowDataSubscriptionCancelParam do
  @moduledoc """
  Provides struct and type for a FlowDataSubscriptionCancelParam
  """

  @type t :: %__MODULE__{retention: Dhc.Stripe.RetentionParam.t() | nil, subscription: String.t()}

  defstruct [:retention, :subscription]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [retention: {Dhc.Stripe.RetentionParam, :t}, subscription: :string]
  end
end
