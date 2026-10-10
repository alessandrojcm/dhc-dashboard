defmodule Dhc.BeginnersWorkshops.DoorView do
  @moduledoc """
  The door view of one Beginners' Workshop (ALE-379): what assigned Staff and
  the managers see when they run it. Its own read shape — never the console
  view minus fields — so it can only ever carry the `beginners.workshops.run`
  data boundary. ALE-379 supplies the header; ALE-390 adds the door list and
  the check-in window. It never carries email, payment or refund details, or
  Waitlist history — a test pins every key.

    * `check_in` — the window (`WorkshopPolicy.check_in_window/2`, the rule
      the `check_in` command applies) and when it opens;
    * `people` — everyone with a seat: Intakes `paid` (and, after
      Attendance Finalisation, `attended` / `no_show`), by name. Each carries
      name, pronouns, Intake state, medical conditions, the check-in record
      (when, and who by name) and, for a minor (under 18 on the workshop
      date), a `minor` badge and the Guardian's name and phone.

  Lock-free and actor-free. `load/2` also returns the assignment-scope
  resource (`assigned_principal_ids`) so the caller authorizes
  `beginners.workshops.run` against the same Staff the view was read with;
  the resource is not part of the view.
  """

  import Ecto.Query

  alias Dhc.BeginnersWorkshops.{
    BeginnersWorkshop,
    Clock,
    Intake,
    WorkshopFacts,
    WorkshopPolicy
  }

  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist.WaitlistGuardian

  # Who has a seat at the door: paid, then the finalised outcomes.
  @door_states ~w(paid attended no_show)

  @type person :: %{
          id: binary(),
          first_name: String.t() | nil,
          last_name: String.t() | nil,
          pronouns: String.t() | nil,
          state: String.t(),
          minor: boolean(),
          medical_conditions: String.t() | nil,
          guardian: %{name: String.t(), phone_number: String.t()} | nil,
          checked_in: %{at: DateTime.t(), by: String.t()} | nil
        }

  @type t :: %{
          id: binary(),
          status: String.t(),
          venue: String.t(),
          date: Date.t(),
          start_time: Time.t(),
          stage: WorkshopPolicy.stage(),
          alerts: [WorkshopPolicy.alert()],
          staff: WorkshopFacts.staff(),
          check_in: %{window: WorkshopPolicy.check_in_window(), opens_at: DateTime.t()},
          people: [person()]
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
        staff: facts.staff,
        check_in: %{
          window: WorkshopPolicy.check_in_window(workshop, reading),
          opens_at: WorkshopPolicy.check_in_opens_at(workshop)
        },
        people: people(workshop)
      }

      {:ok, view, %{assigned_principal_ids: WorkshopFacts.assigned_principal_ids(facts)}}
    else
      _ -> {:error, :not_found}
    end
  end

  defp people(workshop) do
    rows =
      from(i in Intake,
        left_join: p in UserProfile,
        on: p.waitlist_id == i.waitlist_id and not is_nil(i.waitlist_id),
        where: i.workshop_id == ^workshop.id and i.state in ^@door_states,
        order_by: [asc: p.first_name, asc: p.last_name, asc: i.id],
        select: %{
          id: i.id,
          state: i.state,
          profile_id: p.id,
          first_name: p.first_name,
          last_name: p.last_name,
          pronouns: p.pronouns,
          medical_conditions: p.medical_conditions,
          date_of_birth: p.date_of_birth,
          checked_in_at: i.checked_in_at,
          checked_in_by: i.checked_in_by_principal_id
        }
      )
      |> Repo.all()
      |> Enum.map(&Map.put(&1, :minor, WorkshopPolicy.minor?(&1.date_of_birth, workshop.date)))

    guardians = guardians(for row <- rows, row.minor, row.profile_id, do: row.profile_id)
    names = staff_names(for row <- rows, row.checked_in_by, uniq: true, do: row.checked_in_by)

    Enum.map(rows, &person(&1, guardians, names))
  end

  defp person(row, guardians, names) do
    %{
      id: row.id,
      first_name: row.first_name,
      last_name: row.last_name,
      pronouns: row.pronouns,
      state: row.state,
      minor: row.minor,
      medical_conditions: row.medical_conditions,
      # Only a minor's Guardian is shown.
      guardian: if(row.minor, do: Map.get(guardians, row.profile_id)),
      checked_in:
        row.checked_in_at &&
          %{at: row.checked_in_at, by: Map.get(names, row.checked_in_by, "Unnamed member")}
    }
  end

  # Guardians have a name and phone only; the newest per profile wins.
  defp guardians([]), do: %{}

  defp guardians(profile_ids) do
    from(g in WaitlistGuardian,
      where: g.profile_id in ^profile_ids,
      order_by: [asc: g.created_at, asc: g.id],
      select:
        {g.profile_id, %{first_name: g.first_name, last_name: g.last_name, phone: g.phone_number}}
    )
    |> Repo.all()
    |> Map.new(fn {profile_id, g} ->
      {profile_id,
       %{name: WorkshopFacts.display_name(g.first_name, g.last_name), phone_number: g.phone}}
    end)
  end

  # Who checked people in, by name — whether or not they are still on the Staff.
  defp staff_names([]), do: %{}

  defp staff_names(principal_ids) do
    from(p in UserProfile,
      where: p.principal_id in ^principal_ids,
      select: {p.principal_id, p.first_name, p.last_name}
    )
    |> Repo.all()
    |> Map.new(fn {id, first, last} -> {id, WorkshopFacts.display_name(first, last)} end)
  end
end
