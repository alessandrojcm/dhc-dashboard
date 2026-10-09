defmodule Dhc.BeginnersWorkshops.BatchesConcurrencyTest do
  @moduledoc """
  ALE-380: races of the automatic Batch pass on real connections outside the
  SQL sandbox (`Dhc.ConcurrencyHelpers`), because a sandboxed connection
  serializes everything and cannot show a lock bug.

    * Two sweeps on the same due Batch send one Batch: the second, queued
      behind the Beginners' Workshop lock, judges the "no open window" rule
      again under it.
    * Two workshops whose Batches propose the same people contact each person
      once: the pass that loses a person to the other retries from a fresh
      proposal.
  """

  use Dhc.DataCase, async: false

  import Dhc.BeginnersWorkshopFixtures
  import Dhc.ConcurrencyHelpers

  alias Dhc.BeginnersWorkshops

  alias Dhc.BeginnersWorkshops.{
    Batch,
    BeginnersWorkshop,
    Clock,
    Intake,
    IntakeEmailLog,
    WorkshopPolicy
  }

  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist.WaitlistEntry

  @batch_1_at ~U[2026-10-20 09:00:00Z]

  defp send_due(workshop_id),
    do:
      BeginnersWorkshops.execute(:system, {:send_due_batch, workshop_id},
        clock: Clock.fixed(@batch_1_at)
      )

  test "two concurrent sweeps on the same due Batch send one Batch" do
    committed(1, 3, 5, fn %{workshops: [workshop]} ->
      results =
        hold_lock_then(
          "SELECT id FROM beginners_workshops WHERE id = $1 FOR UPDATE",
          [Ecto.UUID.dump!(workshop.id)],
          [fn -> send_due(workshop.id) end, fn -> send_due(workshop.id) end]
        )

      assert Enum.sort_by(results, &inspect/1) |> Enum.map(fn {:ok, %{outcome: o}} -> o end) ==
               [:not_due, :sent]

      assert [%Batch{number: 1, size: 3}] =
               Repo.all(from(b in Batch, where: b.workshop_id == ^workshop.id))

      intakes = Repo.all(from(i in Intake, where: i.workshop_id == ^workshop.id))
      assert Enum.count(intakes) == 3

      assert Repo.aggregate(
               from(l in IntakeEmailLog, where: l.intake_id in ^Enum.map(intakes, & &1.id)),
               :count
             ) == 3
    end)
  end

  test "two workshops proposing the same people contact each person once" do
    committed(2, 2, 4, fn %{workshops: [first, second], people: people} ->
      [earliest | _] = Enum.sort_by(people, & &1.initial_registration_date, DateTime)

      results =
        hold_lock_then(
          "SELECT id FROM waitlist WHERE id = $1 FOR UPDATE",
          [Ecto.UUID.dump!(earliest.id)],
          [fn -> send_due(first.id) end, fn -> send_due(second.id) end]
        )

      assert Enum.all?(results, &match?({:ok, %{outcome: :sent, batch: %{size: 2}}}, &1))

      contacted =
        Repo.all(
          from(i in Intake,
            where: i.workshop_id in ^[first.id, second.id],
            select: i.waitlist_id
          )
        )

      assert Enum.sort(contacted) == Enum.sort(Enum.map(people, & &1.id))
    end)
  end

  # Workshops scheduled straight into the table (no staff principal, so no
  # alert recipients) and waiting people, committed outside the sandbox and
  # deleted afterwards.
  defp committed(workshop_count, capacity, people, fun) do
    ctx =
      outside_sandbox(fn ->
        %{
          workshops: for(_ <- 1..workshop_count, do: insert_workshop!(capacity)),
          people: waiting_people_fixture(people)
        }
      end)

    on_exit(fn -> outside_sandbox(fn -> cleanup!(ctx) end) end)
    outside_sandbox(fn -> fun.(ctx) end)
  end

  defp insert_workshop!(capacity) do
    %{
      venue: "Race Hall",
      date: ~D[2026-11-14],
      start_time: ~T[18:30:00],
      capacity: capacity,
      fee_cents: 4000,
      payment_cutoff: ~U[2026-11-11 18:30:00.000000Z],
      contact_from: ~D[2026-10-20],
      payment_window_days: WorkshopPolicy.default_payment_window_days()
    }
    |> BeginnersWorkshop.schedule_changeset()
    |> Repo.insert!()
  end

  defp cleanup!(%{workshops: workshops, people: people}) do
    workshop_ids = Enum.map(workshops, & &1.id)
    person_ids = Enum.map(people, & &1.id)
    emails = Enum.map(people, & &1.email)

    intake_ids =
      Repo.all(from(i in Intake, where: i.workshop_id in ^workshop_ids, select: i.id))

    Repo.delete_all(from(l in IntakeEmailLog, where: l.intake_id in ^intake_ids))
    Repo.delete_all(from(i in Intake, where: i.id in ^intake_ids))
    Repo.delete_all(from(b in Batch, where: b.workshop_id in ^workshop_ids))
    Repo.delete_all(from(w in BeginnersWorkshop, where: w.id in ^workshop_ids))
    Repo.delete_all(from(j in Oban.Job, where: fragment("?->>'email'", j.args) in ^emails))
    Repo.delete_all(from(p in UserProfile, where: p.waitlist_id in ^person_ids))
    Repo.delete_all(from(e in WaitlistEntry, where: e.id in ^person_ids))
  end
end
