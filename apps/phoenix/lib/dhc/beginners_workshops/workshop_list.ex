defmodule Dhc.BeginnersWorkshops.WorkshopList do
  @moduledoc """
  The Workshops list read model (ALE-378): no locks, no actor (the route's
  capability gate is the whole authorization) — the
  `Dhc.Inventory.OperatorLoanQueue` shape.

  Two groups: **upcoming** (scheduled, soonest first) and **past and
  cancelled** (finalised or cancelled, most recent first). Each row is
  `WorkshopProjection.view/3`, the same shape every workshop command
  returns. Deliberately unpaginated: the club schedules a handful a season.
  """

  import Ecto.Query

  alias Dhc.BeginnersWorkshops.{
    BeginnersWorkshop,
    Clock,
    WorkshopFacts,
    WorkshopProjection
  }

  alias Dhc.Repo

  @type t :: %{upcoming: [WorkshopProjection.t()], past: [WorkshopProjection.t()]}

  @doc "The list at the clock's current reading."
  @spec list(Clock.t()) :: t()
  def list(%Clock{} = clock) do
    workshops =
      Repo.all(
        from(w in BeginnersWorkshop,
          order_by: [asc: w.date, asc: w.start_time, asc: w.id]
        )
      )

    facts = WorkshopFacts.load(Enum.map(workshops, & &1.id))
    reading = Clock.read(clock)
    rows = Enum.map(workshops, &WorkshopProjection.view(&1, Map.fetch!(facts, &1.id), reading))
    {upcoming, past} = Enum.split_with(rows, &(&1.status == "scheduled"))

    %{upcoming: upcoming, past: Enum.reverse(past)}
  end
end
