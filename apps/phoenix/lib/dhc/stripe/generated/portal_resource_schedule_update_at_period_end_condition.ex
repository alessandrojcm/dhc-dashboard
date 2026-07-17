defmodule Dhc.Stripe.PortalResourceScheduleUpdateAtPeriodEndCondition do
  @moduledoc """
  Provides struct and type for a PortalResourceScheduleUpdateAtPeriodEndCondition
  """

  @type t :: %__MODULE__{type: String.t()}

  defstruct [:type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [type: {:enum, ["decreasing_item_amount", "shortening_interval"]}]
  end
end
