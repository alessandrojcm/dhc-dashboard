defmodule Dhc.Stripe.SubscriptionScheduleCurrentPhase do
  @moduledoc """
  Provides struct and type for a SubscriptionScheduleCurrentPhase
  """

  @type t :: %__MODULE__{end_date: integer, start_date: integer}

  defstruct [:end_date, :start_date]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [end_date: {:integer, "unix-time"}, start_date: {:integer, "unix-time"}]
  end
end
