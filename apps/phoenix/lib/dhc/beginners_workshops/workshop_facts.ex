defmodule Dhc.BeginnersWorkshops.WorkshopFacts do
  @moduledoc """
  The facts about a Beginners' Workshop that live outside its own row: paid
  seats, live Seat Holds, Batches, pause state and Staff.

  The boundary reads them under the workshop lock and the read models read
  them without one, through this one module, so an advisory stage or seat
  meter can be stale but never computed differently from the rule the
  boundary applies.

  ALE-378 creates the workshop only, so every workshop has the empty facts.
  The tickets that add Intakes (ALE-381), Batches and pausing (ALE-380) and
  Staff (ALE-379) fill them in here.
  """

  @type t :: %{
          paid: non_neg_integer(),
          holds: non_neg_integer(),
          batches_sent: non_neg_integer(),
          latest_window_end: DateTime.t() | nil,
          batches_paused: boolean(),
          coach_assigned: boolean()
        }

  @empty %{
    paid: 0,
    holds: 0,
    batches_sent: 0,
    latest_window_end: nil,
    batches_paused: false,
    coach_assigned: false
  }

  @doc "The facts for each workshop id."
  @spec load([binary()]) :: %{binary() => t()}
  def load(workshop_ids) when is_list(workshop_ids), do: Map.new(workshop_ids, &{&1, @empty})

  @doc "The facts of a workshop with nothing attached to it."
  @spec empty() :: t()
  def empty, do: @empty
end
