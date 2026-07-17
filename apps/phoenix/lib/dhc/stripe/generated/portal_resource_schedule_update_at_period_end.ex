defmodule Dhc.Stripe.PortalResourceScheduleUpdateAtPeriodEnd do
  @moduledoc """
  Provides struct and type for a PortalResourceScheduleUpdateAtPeriodEnd
  """

  @type t :: %__MODULE__{
          conditions: [Dhc.Stripe.PortalResourceScheduleUpdateAtPeriodEndCondition.t()]
        }

  defstruct [:conditions]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [conditions: [{Dhc.Stripe.PortalResourceScheduleUpdateAtPeriodEndCondition, :t}]]
  end
end
