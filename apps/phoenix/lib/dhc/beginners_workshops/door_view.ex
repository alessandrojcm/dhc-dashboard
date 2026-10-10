defmodule Dhc.BeginnersWorkshops.DoorView do
  @moduledoc """
  The door view of one Beginners' Workshop (ALE-379): what assigned Staff and
  the managers see when they run it. Its own read shape — never the console
  view minus fields — so it can only ever carry the `beginners.workshops.run`
  data boundary. ALE-379 supplies the header; the roster and check-in come
  with the door check-in ticket (ALE-390), and must never add email, payment,
  refund or Waitlist history.

  Lock-free and actor-free. `load/2` also returns the assignment-scope
  resource (`assigned_principal_ids`) so the caller authorizes
  `beginners.workshops.run` against the same Staff the view was read with;
  the resource is not part of the view.
  """

  alias Dhc.BeginnersWorkshops.{BeginnersWorkshop, Clock, WorkshopFacts, WorkshopPolicy}
  alias Dhc.Repo

  @type t :: %{
          id: binary(),
          status: String.t(),
          venue: String.t(),
          date: Date.t(),
          start_time: Time.t(),
          stage: WorkshopPolicy.stage(),
          alerts: [WorkshopPolicy.alert()],
          staff: WorkshopFacts.staff()
        }

  @type resource :: %{assigned_principal_ids: [binary()]}

  @doc "The door view and its assignment-scope resource, or `:not_found`."
  @spec load(term(), Clock.t()) :: {:ok, t(), resource()} | {:error, :not_found}
  def load(workshop_id, %Clock{} = clock) do
    with {:ok, id} <- Ecto.UUID.cast(workshop_id),
         %BeginnersWorkshop{} = workshop <- Repo.get(BeginnersWorkshop, id) do
      facts = Map.fetch!(WorkshopFacts.load([id]), id)
      reading = Clock.read(clock)

      view = %{
        id: workshop.id,
        status: workshop.status,
        venue: workshop.venue,
        date: workshop.date,
        start_time: workshop.start_time,
        stage: WorkshopPolicy.stage(workshop, facts, reading),
        alerts: WorkshopPolicy.alerts(workshop, facts),
        staff: facts.staff
      }

      {:ok, view, %{assigned_principal_ids: WorkshopFacts.assigned_principal_ids(facts)}}
    else
      _ -> {:error, :not_found}
    end
  end
end
