defmodule Dhc.BeginnersWorkshopFixtures do
  @moduledoc "Beginners' Workshop fixtures: staff principals, a fixed clock and scheduled workshops."

  alias Dhc.Auth.UserRole
  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.{BeginnersWorkshop, Clock, Intake}
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist.WaitlistEntry

  # 2026-10-09 12:00 Dublin (IST, UTC+1).
  @now ~U[2026-10-09 11:00:00Z]

  def now, do: @now
  def clock(now \\ @now), do: Clock.fixed(now)

  @doc """
  An active member holding `role` plus `member` (as every real member does);
  returns the principal id. `attrs` go to `Dhc.MemberFixtures.member_fixture/1`.
  """
  def staff_fixture(role \\ "beginners_coordinator", attrs \\ %{}) do
    member = Dhc.MemberFixtures.member_fixture(attrs)

    for role <- Enum.uniq(["member", role]),
        do: Repo.insert!(%UserRole{principal_id: member.principal_id, role: role})

    member.principal_id
  end

  @doc "Sets a workshop's Staff through the boundary (as a fresh coordinator unless given)."
  def set_staff!(workshop_id, coach, assistants \\ [], opts \\ []) do
    actor = Keyword.get_lazy(opts, :actor, fn -> staff_fixture() end)

    {:ok, view} =
      BeginnersWorkshops.execute(
        {:staff, actor},
        {:set_staff, workshop_id,
         %{"coach_principal_id" => coach, "assistant_principal_ids" => assistants}},
        Keyword.put_new(opts, :clock, clock())
      )

    view
  end

  def workshop_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "venue" => "St. Andrew's Hall",
        "date" => "2026-11-14",
        "start_time" => "18:30",
        "capacity" => 16,
        "fee_cents" => 4000
      },
      overrides
    )
  end

  @doc "Schedules one workshop through the boundary and returns its view."
  def scheduled_fixture(staff_id, overrides \\ %{}, opts \\ []) do
    {:ok, [view]} =
      BeginnersWorkshops.execute(
        {:staff, staff_id},
        {:schedule_workshop, [workshop_attrs(overrides)]},
        Keyword.put_new(opts, :clock, clock())
      )

    view
  end

  @doc """
  Test-only: forces a workshop's status. No ALE-378 command finalises or
  cancels; this stands in for the tickets that will.
  """
  def force_status!(workshop_id, status) do
    Repo.get!(BeginnersWorkshop, workshop_id)
    |> Ecto.Changeset.change(status: status)
    |> Repo.update!()
  end

  @doc """
  A `waiting` Waitlist person with an inactive profile. `registered_at` sets
  the priority (`initial_registration_date`); options `first_name`,
  `date_of_birth` and `status`.
  """
  def waiting_person_fixture(registered_at, opts \\ []) do
    status = Keyword.get(opts, :status, "waiting")
    at = DateTime.truncate(registered_at, :second)

    entry =
      Repo.insert!(%WaitlistEntry{
        email: "#{System.unique_integer([:positive])}@waitlist.example.com",
        status: status,
        removed_at: if(status == "removed", do: at),
        initial_registration_date: at,
        last_status_change: at
      })

    Repo.insert!(%UserProfile{
      waitlist_id: entry.id,
      first_name: Keyword.get(opts, :first_name, "Person#{System.unique_integer([:positive])}"),
      last_name: "Waiting",
      phone_number: "+353810000000",
      date_of_birth: Keyword.get(opts, :date_of_birth, ~D[1995-05-05]),
      gender: "non-binary",
      pronouns: "they/them",
      is_active: false,
      social_media_consent: "no"
    })

    Repo.get!(WaitlistEntry, entry.id)
  end

  @doc "`count` waiting people registered a day apart, oldest first."
  def waiting_people_fixture(count, from \\ ~U[2025-01-01 12:00:00Z]) do
    for index <- 0..(count - 1)//1,
        do: waiting_person_fixture(DateTime.add(from, index * 86_400, :second))
  end

  @doc "Test-only: forces an Intake's state (no ALE-380 command pays an Intake)."
  def force_intake_state!(intake_id, state) do
    Repo.get!(Intake, intake_id)
    |> Ecto.Changeset.change(state: state)
    |> Repo.update!()
  end
end
