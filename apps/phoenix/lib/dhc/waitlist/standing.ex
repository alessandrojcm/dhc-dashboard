defmodule Dhc.Waitlist.Standing do
  @moduledoc """
  The Waitlist standing rules (ALE-375, ADR 0029): which Waitlist Status can
  change to which.

  Waitlist Status is a person's standing in the queue, independent of any one
  Beginners' Workshop. What happened at a particular workshop belongs to that
  workshop's Intake, never to the standing. Standing changes only through
  `Dhc.Waitlist.change_standing/2`, which asks `allowed?/2` and refuses every
  other change; there is no status field to edit.
  """

  @statuses ~w(waiting removed attended invited joined)

  @transitions %{
    "waiting" => ~w(removed attended),
    "removed" => ~w(waiting attended),
    "attended" => ~w(removed invited),
    "invited" => ~w(attended joined),
    "joined" => []
  }

  @doc "Every Waitlist Status, in queue order."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Whether a standing may change from `from` to `to`."
  @spec allowed?(String.t(), String.t()) :: boolean()
  def allowed?(from, to), do: to in Map.get(@transitions, from, [])
end
