defmodule Dhc.BeginnersWorkshops.SettlementFinalisationTest do
  @moduledoc """
  ALE-404: Attendance Finalisation's Settlement spends or forfeits only the
  Carried Fee it locked as applied to a paid Intake, and does nothing when
  there is none, so one Intake whose fee moved on never blocks the
  workshop's finalisation (the pre-Settlement `end_fee/3` behaviour). The
  fee is moved out of `applied` by a direct fixture write: no command
  produces that state.

  The workshop under test: Saturday 14 November 2026 at 18:30 Dublin.
  """

  use Dhc.DataCase, async: true
  use Oban.Testing, repo: Dhc.Repo

  import Dhc.BeginnersWorkshopFixtures

  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.{CarriedFee, Clock, Intake, IntakeLink}
  alias Dhc.Repo
  alias Dhc.Waitlist.WaitlistEntry

  @now ~U[2026-10-22 12:00:00.000000Z]
  @day_ended ~U[2026-11-15 01:00:00.000000Z]

  setup do
    %{coordinator: staff_fixture("beginners_coordinator", %{first_name: "Clare"})}
  end

  defp execute(actor, command, at \\ @now),
    do: BeginnersWorkshops.execute(actor, command, clock: Clock.fixed(at))

  defp holder!(registered_at) do
    person = waiting_person_fixture(registered_at)
    assert {:ok, %{outcome: :created}} = execute(:system, {:import_carried_fee, person.id, "Yes"})
    person
  end

  defp fee!(%WaitlistEntry{id: id}),
    do: Repo.one!(from(f in CarriedFee, where: f.waitlist_id == ^id))

  defp intake_of(workshop, person),
    do:
      Repo.one!(
        from(i in Intake, where: i.workshop_id == ^workshop.id and i.waitlist_id == ^person.id)
      )

  defp confirm!(intake) do
    token = IntakeLink.token(intake.id, intake.link_generation)
    assert {:ok, %{outcome: :done}} = execute({:intake_link, token}, :confirm)
  end

  test "a Carried-Fee-paid Intake whose fee is no longer applied is finalised without touching it",
       %{coordinator: c} do
    moved_on = holder!(~U[2024-06-01 12:00:00Z])
    attending = holder!(~U[2024-06-02 12:00:00Z])

    workshop = scheduled_fixture(c, %{"contact_from" => "2026-10-20", "capacity" => 2})

    assert {:ok, %{outcome: :sent}} =
             execute(:system, {:send_due_batch, workshop.id}, batch_1_at())

    [m, a] = Enum.map([moved_on, attending], &intake_of(workshop, &1))
    confirm!(m)
    confirm!(a)

    a
    |> Repo.reload!()
    |> Ecto.Changeset.change(checked_in_at: @now, checked_in_by_principal_id: c)
    |> Repo.update!()

    # The state no command produces: the paying fee left `applied`.
    moved_on
    |> fee!()
    |> Ecto.Changeset.change(status: "held", applied_intake_id: nil)
    |> Repo.update!()

    assert {:ok, %{outcome: :finalised, attended: 1, no_show: 1}} =
             execute(:system, {:finalise_attendance, workshop.id}, @day_ended)

    assert %Intake{state: "no_show"} = Repo.reload!(m)
    assert %CarriedFee{status: "held", applied_intake_id: nil} = fee!(moved_on)
    assert %Intake{state: "attended"} = Repo.reload!(a)
    assert %CarriedFee{status: "spent"} = fee!(attending)
  end
end
