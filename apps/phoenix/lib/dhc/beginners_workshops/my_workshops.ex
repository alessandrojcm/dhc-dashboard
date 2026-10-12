defmodule Dhc.BeginnersWorkshops.MyWorkshops do
  @moduledoc """
  "My Beginners' Workshops" (ALE-379): the caller's upcoming and same-day
  Staff assignments. A lock-free read model; its only input is the caller's
  own principal id, so it needs no capability beyond
  `beginners.workshops.assigned.read` (every member).

  Upcoming is a scheduled workshop on a later Dublin date; same-day is any
  workshop on Dublin today that was not cancelled (a workshop finished at the
  door stays listed for the rest of its day). Soonest first. Each row is a
  closed shape that names the caller's role and nothing about the roster.
  """

  import Ecto.Query

  alias Dhc.BeginnersWorkshops.{
    BeginnersWorkshop,
    Clock,
    StaffAssignment,
    WorkshopFacts,
    WorkshopPolicy
  }

  alias Dhc.Repo

  @type row :: %{
          id: binary(),
          status: String.t(),
          venue: String.t(),
          date: Date.t(),
          start_time: Time.t(),
          stage: WorkshopPolicy.stage(),
          role: String.t()
        }

  @doc "The principal's upcoming and same-day assignments at the clock's reading."
  @spec list(binary(), Clock.t()) :: [row()]
  def list(principal_id, %Clock{} = clock) when is_binary(principal_id) do
    reading = Clock.read(clock)
    today = reading.today

    rows =
      Repo.all(
        from(w in BeginnersWorkshop,
          join: s in StaffAssignment,
          on: s.workshop_id == w.id,
          where: s.principal_id == ^principal_id,
          where:
            (w.date > ^today and w.status == "scheduled") or
              (w.date == ^today and w.status != "cancelled"),
          order_by: [asc: w.date, asc: w.start_time, asc: w.id],
          select: {w, s.role}
        )
      )

    facts = WorkshopFacts.load(Enum.map(rows, fn {w, _role} -> w.id end))

    Enum.map(rows, fn {workshop, role} ->
      %{
        id: workshop.id,
        status: workshop.status,
        venue: workshop.venue,
        date: workshop.date,
        start_time: workshop.start_time,
        stage: WorkshopPolicy.stage(workshop, Map.fetch!(facts, workshop.id), reading),
        role: role
      }
    end)
  end
end
