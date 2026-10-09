defmodule Dhc.BeginnersWorkshopFixtures do
  @moduledoc "Beginners' Workshop fixtures: staff principals, a fixed clock and scheduled workshops."

  alias Dhc.Auth.UserRole
  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.{BeginnersWorkshop, Clock}
  alias Dhc.Repo

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
end
