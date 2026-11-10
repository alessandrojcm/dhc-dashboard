defmodule Dhc.BeginnersWorkshops.DestinationEnrichmentTest do
  @moduledoc """
  ALE-444: the reviewed backfill's Beginners' Workshop apply — the
  `enrich_destination` command behind `execute/3`, reached through
  `Dhc.BeginnersWorkshops.enrich_destination/4` — with real persistence,
  real public commands between review and apply, and fixed clocks.

  The contacted workshop (`contacted_fixture/3`) is Saturday 14 November 2026
  at 18:30 Dublin (18:30 UTC), Payment Cutoff 11 November 18:30 UTC, Batch 1
  sent at 10:00 on 20 October.
  """

  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  import Dhc.BeginnersWorkshopFixtures
  import Dhc.ConcurrencyHelpers

  alias Dhc.Auth.{Principal, UserRole}
  alias Dhc.BeginnersWorkshops

  alias Dhc.BeginnersWorkshops.{
    Batch,
    BeginnersWorkshop,
    Clock,
    DestinationEnrichment,
    Intake,
    IntakeEmailLog,
    IntakeEvent,
    StaffAssignment
  }

  alias Dhc.Email.Worker
  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Notifications.Notification
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.WorkshopCalendar.Event
  alias Dhc.WorkshopCalendar.Workers.SyncWorker

  @now ~U[2026-10-22 12:00:00.000000Z]
  @start ~U[2026-11-14 18:30:00Z]

  @arena %{
    destination_name: "National Basketball Arena",
    destination_address: "Tymon Park, Dublin 6w",
    directions_url: "https://maps.app.goo.gl/AbCdEf"
  }
  @none %{destination_name: nil, destination_address: nil, directions_url: nil}

  setup do
    %{coordinator: staff_fixture("beginners_coordinator")}
  end

  describe "applying a reviewed enrichment" do
    test "changes only the destination: no reschedule, email, Notification or place change",
         %{coordinator: coordinator} do
      {view, intakes} = contacted_fixture(coordinator, 2)
      coach = staff_fixture("coach")
      set_staff!(view.id, coach, [], actor: coordinator, clock: Clock.fixed(@now))
      workshop = stored(view)

      batches = rows(Batch, view)
      staff = rows(StaffAssignment, view)
      logs = Repo.all(IntakeEmailLog)
      events = Repo.all(IntakeEvent)
      emails = all_enqueued(worker: Worker)
      notifications = Repo.all(Notification)
      revision = committee_event(view.id).revision

      assert {:ok, :changed} = enrich(coordinator, workshop)

      updated = stored(view)
      assert Map.take(updated, Map.keys(@arena)) == @arena

      unrelated =
        ~w(venue date start_time end_time payment_cutoff contact_from payment_window_days
           capacity fee_cents reschedule_count status batches_paused finalised_at cancelled_at)a

      assert Map.take(updated, unrelated) == Map.take(workshop, unrelated)
      assert rows(Batch, view) == batches
      assert rows(StaffAssignment, view) == staff
      assert Repo.all(IntakeEmailLog) == logs
      assert Repo.all(IntakeEvent) == events
      assert all_enqueued(worker: Worker) == emails
      assert Repo.all(Notification) == notifications

      for {intake, _token} <- intakes, do: assert(Repo.reload!(intake) == intake)

      # Identifier-only Calendar intent, in the same transaction.
      assert committee_event(view.id).revision == revision + 1

      assert_enqueued(
        worker: SyncWorker,
        args: %{source_kind: "beginners_workshop", source_id: view.id}
      )
    end

    test "repeating it writes nothing and records no Calendar intent", %{coordinator: coordinator} do
      workshop = scheduled!(coordinator)
      assert {:ok, :changed} = enrich(coordinator, workshop)
      after_first = stored(workshop)
      event = committee_event(workshop.id)
      jobs = sync_jobs(workshop.id)

      # The same reviewed target again, and one reviewed after the change.
      assert {:ok, :unchanged} = enrich(coordinator, workshop)
      assert {:ok, :unchanged} = enrich(coordinator, workshop, expected: expected(after_first))

      assert stored(workshop) == after_first
      assert committee_event(workshop.id) == event
      assert sync_jobs(workshop.id) == jobs
    end

    test "fills absent fields when the stored ones already agree", %{coordinator: coordinator} do
      workshop =
        scheduled!(coordinator, %{"destination_name" => @arena.destination_name})

      assert {:ok, :changed} = enrich(coordinator, workshop)
      assert Map.take(stored(workshop), Map.keys(@arena)) == @arena
    end

    test "a workshop with no known end time is enriched against its reviewed nil end",
         %{coordinator: coordinator} do
      workshop = scheduled!(coordinator)

      Repo.update_all(from(w in BeginnersWorkshop, where: w.id == ^workshop.id),
        set: [end_time: nil]
      )

      workshop = stored(workshop)

      assert %{end_time: nil, ends_at: nil} = DestinationEnrichment.facts(workshop)
      assert {:ok, :changed} = enrich(coordinator, workshop)
    end
  end

  describe "authorization" do
    test "anyone without beginners.workshops.manage is refused before any read",
         %{coordinator: coordinator} do
      workshop = scheduled!(coordinator)

      for actor <- [
            {:staff, staff_fixture("coach")},
            {:staff, staff_fixture("workshop_coordinator")},
            {:staff, "not-a-uuid"},
            :system
          ] do
        assert {:error, :forbidden} =
                 BeginnersWorkshops.enrich_destination(actor, workshop.id, review(workshop),
                   clock: fn -> @now end
                 )
      end

      assert stored(workshop) == workshop
    end
  end

  describe "refusals under the lock, after real commands" do
    test "a genuine reschedule since review is refused, never overwritten",
         %{coordinator: coordinator} do
      workshop = scheduled!(coordinator)
      reviewed = expected(workshop)

      assert {:ok, _} =
               run(coordinator, {:reschedule_workshop, workshop.id, times("19:00", "21:00")})

      assert {:error, :rescheduled} = enrich(coordinator, workshop, expected: reviewed)
      assert Map.take(stored(workshop), Map.keys(@arena)) == @none
      assert stored(workshop).reschedule_count == 1
    end

    test "a venue move since review is refused as a label change", %{coordinator: coordinator} do
      workshop = scheduled!(coordinator)
      reviewed = expected(workshop)

      assert {:ok, _} =
               run(
                 coordinator,
                 {:reschedule_workshop, workshop.id,
                  Map.put(times("18:30", "20:30"), "venue", "The Hub")}
               )

      assert {:error, :label_changed} = enrich(coordinator, workshop, expected: reviewed)
      assert Map.take(stored(workshop), Map.keys(@arena)) == @none
    end

    test "a destination edited since review is refused", %{coordinator: coordinator} do
      workshop = scheduled!(coordinator)
      reviewed = expected(workshop)

      assert {:ok, _} =
               run(
                 coordinator,
                 {:update_destination, workshop.id,
                  %{"venue" => workshop.venue, "destination_name" => "Seen elsewhere"}}
               )

      assert {:error, :destination_changed} = enrich(coordinator, workshop, expected: reviewed)
      assert stored(workshop).destination_name == "Seen elsewhere"
    end

    test "a cancellation since review is refused", %{coordinator: coordinator} do
      workshop = scheduled!(coordinator)
      reviewed = expected(workshop)
      assert {:ok, _} = run(coordinator, {:cancel_workshop, workshop.id, %{}})

      assert {:error, :cancelled} = enrich(coordinator, workshop, expected: reviewed)
      assert Map.take(stored(workshop), Map.keys(@arena)) == @none
    end

    test "finalised, missing and conflicting workshops are refused", %{coordinator: coordinator} do
      finalised = scheduled!(coordinator)
      reviewed = expected(finalised)
      force_status!(finalised.id, "finalised")
      assert {:error, :not_eligible_status} = enrich(coordinator, finalised, expected: reviewed)

      assert {:error, :not_found} =
               BeginnersWorkshops.enrich_destination(
                 {:staff, coordinator},
                 Ecto.UUID.generate(),
                 review(finalised),
                 clock: fn -> @now end
               )

      conflicting = scheduled!(coordinator, %{"destination_address" => "Another street"})
      assert {:error, :destination_conflict} = enrich(coordinator, conflicting)
      assert stored(conflicting) == conflicting
    end

    test "a stale status in the reviewed facts is refused", %{coordinator: coordinator} do
      workshop = scheduled!(coordinator)

      assert {:error, :status_changed} =
               enrich(coordinator, workshop,
                 expected: %{expected(workshop) | status: "finalised"}
               )
    end

    test "the start boundary is judged on the boundary clock read under the lock",
         %{coordinator: coordinator} do
      workshop = scheduled!(coordinator)

      assert {:error, :started} = enrich(coordinator, workshop, now: @start)
      assert {:error, :started} = enrich(coordinator, workshop, now: DateTime.add(@start, 60))
      assert {:ok, :changed} = enrich(coordinator, workshop, now: DateTime.add(@start, -1))
    end

    test "an invalid proposal is refused without a write", %{coordinator: coordinator} do
      workshop = scheduled!(coordinator)
      bad = %{@arena | directions_url: "https://example.com/not-maps"}

      assert {:error, :invalid_destination} =
               BeginnersWorkshops.enrich_destination(
                 {:staff, coordinator},
                 workshop.id,
                 %{expected: expected(workshop), destination: bad},
                 clock: Clock.fixed(@now)
               )

      assert stored(workshop) == workshop
    end
  end

  test "the advisory check agrees with the locked rule", %{coordinator: coordinator} do
    workshop = scheduled!(coordinator)
    facts = DestinationEnrichment.facts(workshop)

    assert BeginnersWorkshops.check_destination_enrichment(facts, @arena, @now) == :change
    assert BeginnersWorkshops.check_destination_enrichment(facts, @none, @now) == :unchanged

    assert BeginnersWorkshops.check_destination_enrichment(facts, @arena, @start) ==
             {:refused, :started}

    assert BeginnersWorkshops.check_destination_enrichment(nil, @arena, @now) ==
             {:refused, :not_found}

    # Dublin civil values, as stored; the instant is Calendar's reading.
    assert {facts.date, facts.start_time, facts.end_time} ==
             {~D[2026-11-14], ~T[18:30:00], ~T[20:30:00]}

    assert facts.starts_at == @start
    assert facts.label == "St. Andrew's Hall"
  end

  describe "concurrent source changes" do
    test "a reschedule committed while enrichment waits for the lock wins" do
      %{staff: staff, workshop: workshop} = ctx = committed!()
      reviewed = expected(workshop)

      [result] =
        while_locked(
          workshop.id,
          fn ->
            {:ok, _} = run(staff, {:reschedule_workshop, workshop.id, times("19:00", "21:00")})
          end,
          [fn -> enrich(staff, workshop, expected: reviewed) end]
        )

      assert result == {:error, :rescheduled}

      outside_sandbox(fn ->
        assert Map.take(stored(workshop), Map.keys(@arena)) == @none
      end)

      cleanup_later(ctx)
    end

    test "a cancellation committed while enrichment waits for the lock wins" do
      %{staff: staff, workshop: workshop} = ctx = committed!()

      [result] =
        while_locked(
          workshop.id,
          fn -> {:ok, _} = run(staff, {:cancel_workshop, workshop.id, %{}}) end,
          [fn -> enrich(staff, workshop) end]
        )

      assert result == {:error, :cancelled}
      cleanup_later(ctx)
    end

    test "two applications of the same target change it exactly once" do
      %{staff: staff, workshop: workshop} = ctx = committed!()
      revision = outside_sandbox(fn -> committee_event(workshop.id).revision end)

      results =
        while_locked(workshop.id, fn -> :ok end, [
          fn -> enrich(staff, workshop) end,
          fn -> enrich(staff, workshop) end
        ])

      assert Enum.sort(results) == [{:ok, :changed}, {:ok, :unchanged}]

      outside_sandbox(fn ->
        assert committee_event(workshop.id).revision == revision + 1
      end)

      cleanup_later(ctx)
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────

  defp run(actor, command),
    do: BeginnersWorkshops.execute({:staff, actor}, command, clock: Clock.fixed(@now))

  defp enrich(staff, workshop, opts \\ []) do
    now = Keyword.get(opts, :now, @now)
    review = %{review(workshop) | expected: Keyword.get(opts, :expected, expected(workshop))}

    # The workflow passes a bare `(-> DateTime.t())`, as for regular Workshops.
    BeginnersWorkshops.enrich_destination({:staff, staff}, workshop.id, review,
      clock: fn -> now end
    )
  end

  defp review(workshop), do: %{expected: expected(workshop), destination: @arena}

  defp expected(workshop) do
    workshop
    |> stored()
    |> DestinationEnrichment.facts()
    |> Map.take([:label, :status, :date, :start_time, :end_time, :destination])
  end

  defp times(start_time, end_time), do: %{"start_time" => start_time, "end_time" => end_time}

  defp scheduled!(coordinator, overrides \\ %{}),
    do: coordinator |> scheduled_fixture(overrides) |> stored()

  defp stored(%{id: id}), do: Repo.get!(BeginnersWorkshop, id)

  defp rows(schema, workshop),
    do: Repo.all(from(r in schema, where: r.workshop_id == ^workshop.id, order_by: r.id))

  defp committee_event(id),
    do:
      Repo.get_by(Event, source_kind: "beginners_workshop", source_id: id, audience: "committee")

  defp sync_jobs(id) do
    Repo.all(
      from(j in Oban.Job,
        where: fragment("?->>'source_id'", j.args) == ^id,
        order_by: j.id,
        select: j.id
      )
    )
  end

  # Holds the Beginners' Workshop row lock while `change` runs in the same
  # transaction, proves every enrichment queues behind it, then commits.
  defp while_locked(workshop_id, change, enrichments) do
    parent = self()

    holder = Task.async(fn -> outside_sandbox(fn -> hold!(workshop_id, change, parent) end) end)

    assert_receive :locked, 5_000
    tasks = Enum.map(enrichments, fn fun -> Task.async(fn -> outside_sandbox(fun) end) end)

    try do
      :ok = wait_for_lock_waiter("%beginners_workshops%")
      Enum.each(tasks, &assert(Task.yield(&1, 200) == nil))
    after
      send(holder.pid, :release)
    end

    assert {:ok, _} = Task.await(holder, 5_000)
    Enum.map(tasks, &Task.await(&1, 5_000))
  end

  defp hold!(workshop_id, change, parent) do
    Repo.transaction(fn ->
      Repo.one!(from(w in BeginnersWorkshop, where: w.id == ^workshop_id, lock: "FOR UPDATE"))
      change.()
      send(parent, :locked)
      receive do: (:release -> :ok)
    end)
  end

  defp committed! do
    outside_sandbox(fn ->
      staff = staff_fixture("beginners_coordinator")
      %{staff: staff, workshop: scheduled!(staff)}
    end)
  end

  defp cleanup_later(%{staff: staff, workshop: workshop}) do
    on_exit(fn ->
      outside_sandbox(fn ->
        id = workshop.id
        Repo.delete_all(from(j in Oban.Job, where: fragment("?->>'source_id'", j.args) == ^id))
        Repo.delete_all(from(e in Event, where: e.source_id == ^id))
        Repo.delete_all(from(i in Intake, where: i.workshop_id == ^id))
        Repo.delete_all(from(w in BeginnersWorkshop, where: w.id == ^id))
        Repo.delete_all(from(r in UserRole, where: r.principal_id == ^staff))
        Repo.delete_all(from(mp in MemberProfile, where: mp.id == ^staff))
        Repo.delete_all(from(up in UserProfile, where: up.principal_id == ^staff))
        Repo.delete_all(from(p in Principal, where: p.id == ^staff))
      end)
    end)
  end
end
