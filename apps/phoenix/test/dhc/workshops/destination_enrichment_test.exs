defmodule Dhc.Workshops.DestinationEnrichmentTest do
  @moduledoc """
  ALE-443: the narrow Workshops-owned same-Venue enrichment
  (`Dhc.Workshops.enrich_destination/4`), through the public operation with
  real persistence and fixed clocks.
  """
  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  import Ecto.Query
  import Dhc.ConcurrencyHelpers

  alias Dhc.Auth.{Principal, UserRole}
  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.WorkshopCalendar.Event
  alias Dhc.WorkshopCalendar.Workers.SyncWorker
  alias Dhc.WorkshopFixtures
  alias Dhc.Workshops
  alias Dhc.Workshops.{DestinationEnrichment, Registration, Workshop}

  @now ~U[2027-03-01 12:00:00Z]
  @start ~U[2027-03-28 09:00:00Z]
  @finish ~U[2027-03-28 11:00:00Z]

  @arena %{
    destination_text: "National Basketball Arena, Tymon Park, Dublin 6w",
    destination_place_id: nil
  }
  @none %{
    destination_text: nil,
    destination_place_id: nil
  }

  setup do
    %{staff: staff!()}
  end

  describe "applying a reviewed enrichment" do
    test "enriches a published Workshop outside the edit window and changes nothing else",
         %{staff: staff} do
      workshop = published!()
      member = WorkshopFixtures.member_fixture()

      registration =
        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          member_user_id: member.principal_id,
          status: "confirmed"
        )

      # The ordinary editor stays closed to a published Workshop.
      assert {:error, :not_editable} =
               Workshops.update_workshop(workshop.id, %{destination_text: "Elsewhere"})

      assert {:ok, :changed} = enrich(staff, workshop)

      updated = Repo.get!(Workshop, workshop.id)
      assert Map.take(updated, Map.keys(@arena)) == @arena

      unrelated =
        ~w(title description location start_date end_date max_capacity price_member
        price_non_member is_public refund_days status announce_discord announce_email created_by archived_at)a

      assert Map.take(updated, unrelated) == Map.take(workshop, unrelated)
      assert Repo.get!(Registration, registration.id) == registration

      # Identifier-only Calendar intent, in the same transaction.
      assert_enqueued(
        worker: SyncWorker,
        args: %{source_kind: "workshop", source_id: workshop.id}
      )

      assert %Event{revision: 2} = committee_event(workshop.id)
    end

    test "repeating the same enrichment writes nothing and records no Calendar intent",
         %{staff: staff} do
      workshop = published!()
      assert {:ok, :changed} = enrich(staff, workshop)
      after_first = Repo.get!(Workshop, workshop.id)
      event = committee_event(workshop.id)
      jobs = sync_jobs(workshop.id)

      # The same reviewed target again, and one reviewed after the change.
      assert {:ok, :unchanged} = enrich(staff, workshop)
      assert {:ok, :unchanged} = enrich(staff, workshop, expected: expected(after_first))

      assert Repo.get!(Workshop, workshop.id) == after_first
      assert committee_event(workshop.id) == event
      assert sync_jobs(workshop.id) == jobs
    end
  end

  describe "authorization" do
    test "a principal without workshops.manage is refused before any read" do
      member = WorkshopFixtures.member_fixture()
      workshop = published!()

      assert {:error, :forbidden} = enrich(member.principal_id, workshop)

      assert {:error, :forbidden} =
               Workshops.enrich_destination(
                 {:staff, member.principal_id},
                 Ecto.UUID.generate(),
                 review(workshop),
                 clock: fn -> @now end
               )

      assert {:error, :forbidden} =
               Workshops.enrich_destination(:system, workshop.id, review(workshop),
                 clock: fn -> @now end
               )

      assert Repo.get!(Workshop, workshop.id) == workshop
      assert sync_jobs(workshop.id) == []
    end

    test "an inactive coordinator is refused" do
      workshop = published!()
      assert {:error, :forbidden} = enrich(staff!(is_active: false), workshop)
    end
  end

  describe "refusals under the lock" do
    test "stale reviewed facts are reported, never overwritten", %{staff: staff} do
      workshop = published!()
      reviewed = expected(workshop)

      cases = [
        label_changed: %{reviewed | label: "Another hall"},
        rescheduled: %{reviewed | start_time: ~T[11:00:00]},
        rescheduled: %{reviewed | date: Date.add(reviewed.date, 1)},
        status_changed: %{reviewed | status: "planned"},
        destination_changed: %{reviewed | destination: %{@none | destination_text: "Seen"}}
      ]

      for {reason, stale} <- cases do
        assert {:error, ^reason} = enrich(staff, workshop, expected: stale)
      end

      assert Repo.get!(Workshop, workshop.id) == workshop
      assert sync_jobs(workshop.id) == []
    end

    test "a different stored destination is a conflict, not enrichment", %{staff: staff} do
      workshop = published!(destination_text: "Another street")
      assert {:error, :destination_conflict} = enrich(staff, workshop)
      assert Repo.get!(Workshop, workshop.id) == workshop
    end

    # ALE-442: a Google-selected destination is never "absent", so a reviewed
    # manual mapping cannot overwrite it or strip its provider identity.
    test "a Google-selected destination is a conflict, not enrichment", %{staff: staff} do
      workshop =
        published!(
          destination_provider: "google",
          destination_place_id: "ChIJ-selected",
          destination_selected_at: ~U[2027-02-01 12:00:00Z]
        )

      assert {:error, :destination_conflict} = enrich(staff, workshop)
      assert Repo.get!(Workshop, workshop.id) == workshop
    end

    test "cancelled, archived and deleted Workshops are refused", %{staff: staff} do
      cancelled = published!()
      assert {:ok, _} = Workshops.cancel_workshop(cancelled.id)
      assert {:error, :cancelled} = enrich(staff, cancelled)

      archived = published!()
      member = WorkshopFixtures.member_fixture()

      WorkshopFixtures.registration_fixture(
        workshop_id: archived.id,
        member_user_id: member.principal_id,
        status: "confirmed"
      )

      assert {:ok, :archived, _} = Workshops.delete_workshop(archived.id)
      assert {:error, :archived} = enrich(staff, archived)

      deleted = published!()
      assert {:ok, :deleted} = Workshops.delete_workshop(deleted.id)
      assert {:error, :not_found} = enrich(staff, deleted)
    end

    test "the start boundary is judged on the clock read under the lock", %{staff: staff} do
      workshop = published!()

      assert {:error, :started} = enrich(staff, workshop, now: @start)
      assert {:error, :started} = enrich(staff, workshop, now: DateTime.add(@start, 60))
      assert {:ok, :changed} = enrich(staff, workshop, now: DateTime.add(@start, -1))
    end

    test "an invalid proposal is refused without a write", %{staff: staff} do
      workshop = published!()
      bad = %{@arena | destination_text: String.duplicate("a", 501)}

      assert {:error, :invalid_destination} =
               Workshops.enrich_destination(
                 {:staff, staff},
                 workshop.id,
                 %{expected: expected(workshop), destination: bad},
                 clock: fn -> @now end
               )

      assert Repo.get!(Workshop, workshop.id) == workshop
    end
  end

  test "the advisory check agrees with the locked rule" do
    workshop = published!()
    facts = DestinationEnrichment.facts(workshop)

    assert Workshops.check_destination_enrichment(facts, @arena, @now) == :change
    assert Workshops.check_destination_enrichment(facts, @none, @now) == :unchanged
    assert Workshops.check_destination_enrichment(facts, @arena, @start) == {:refused, :started}
    assert Workshops.check_destination_enrichment(nil, @arena, @now) == {:refused, :not_found}

    assert facts.date == ~D[2027-03-28]
    # Dublin summer time began at 01:00 UTC that morning.
    assert {facts.start_time, facts.end_time} == {~T[10:00:00], ~T[12:00:00]}
  end

  describe "concurrent source changes" do
    test "a reschedule committed while enrichment waits for the lock wins" do
      %{staff: staff, workshop: workshop} = ctx = committed!(status: "planned")
      reviewed = expected(workshop)

      [result] =
        while_locked(
          workshop.id,
          fn ->
            {:ok, _} =
              Workshops.update_workshop(workshop.id, %{
                start_date: DateTime.add(@start, 3600),
                end_date: DateTime.add(@finish, 3600)
              })
          end,
          [fn -> enrich(staff, workshop, expected: reviewed) end]
        )

      assert result == {:error, :rescheduled}

      outside_sandbox(fn ->
        assert Map.take(Repo.get!(Workshop, workshop.id), Map.keys(@arena)) == @none
      end)

      cleanup_later(ctx)
    end

    test "a cancellation committed while enrichment waits for the lock wins" do
      %{staff: staff, workshop: workshop} = ctx = committed!(status: "published")

      [result] =
        while_locked(
          workshop.id,
          fn -> {:ok, _} = Workshops.cancel_workshop(workshop.id) end,
          [fn -> enrich(staff, workshop) end]
        )

      assert result == {:error, :cancelled}
      cleanup_later(ctx)
    end

    test "two applications of the same target change it exactly once" do
      %{staff: staff, workshop: workshop} = ctx = committed!(status: "published")

      results =
        while_locked(workshop.id, fn -> :ok end, [
          fn -> enrich(staff, workshop) end,
          fn -> enrich(staff, workshop) end
        ])

      # The second finds the reviewed end state already in place.
      assert Enum.sort(results) == [{:ok, :changed}, {:ok, :unchanged}]

      outside_sandbox(fn ->
        assert %Event{revision: 2} = committee_event(workshop.id)
      end)

      cleanup_later(ctx)
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────

  defp enrich(staff, workshop, opts \\ []) do
    now = Keyword.get(opts, :now, @now)
    review = %{review(workshop) | expected: Keyword.get(opts, :expected, expected(workshop))}
    Workshops.enrich_destination({:staff, staff}, workshop.id, review, clock: fn -> now end)
  end

  defp review(workshop), do: %{expected: expected(workshop), destination: @arena}

  defp expected(workshop) do
    facts = DestinationEnrichment.facts(workshop)
    Map.take(facts, [:label, :status, :date, :start_time, :end_time, :destination])
  end

  defp published!(attrs \\ []) do
    [status: "published", start_date: @start, end_date: @finish]
    |> Keyword.merge(attrs)
    |> WorkshopFixtures.workshop_fixture()
  end

  defp staff!(attrs \\ []) do
    member = WorkshopFixtures.member_fixture(Map.new(attrs))

    for role <- ["member", "workshop_coordinator"],
        do: Repo.insert!(%UserRole{principal_id: member.principal_id, role: role})

    member.principal_id
  end

  defp committee_event(workshop_id),
    do: Repo.get_by(Event, source_kind: "workshop", source_id: workshop_id, audience: "committee")

  defp sync_jobs(workshop_id) do
    Repo.all(
      from(j in Oban.Job,
        where: fragment("?->>'source_id'", j.args) == ^workshop_id,
        order_by: j.id,
        select: j.id
      )
    )
  end

  # Holds the Workshop row lock while `change` runs in the same transaction,
  # proves every enrichment queues behind it, then commits the change.
  defp while_locked(workshop_id, change, enrichments) do
    parent = self()

    holder = Task.async(fn -> outside_sandbox(fn -> hold!(workshop_id, change, parent) end) end)

    assert_receive :locked, 5_000
    tasks = Enum.map(enrichments, fn fun -> Task.async(fn -> outside_sandbox(fun) end) end)

    try do
      :ok = wait_for_lock_waiter("%club_activities%")
      Enum.each(tasks, &assert(Task.yield(&1, 200) == nil))
    after
      send(holder.pid, :release)
    end

    assert {:ok, _} = Task.await(holder, 5_000)
    Enum.map(tasks, &Task.await(&1, 5_000))
  end

  defp hold!(workshop_id, change, parent) do
    Repo.transaction(fn ->
      Repo.one!(from(w in Workshop, where: w.id == ^workshop_id, lock: "FOR UPDATE"))
      change.()
      send(parent, :locked)
      receive do: (:release -> :ok)
    end)
  end

  defp committed!(attrs) do
    outside_sandbox(fn ->
      %{staff: staff!(), workshop: published!(attrs)}
    end)
  end

  defp cleanup_later(%{staff: staff, workshop: workshop}) do
    on_exit(fn ->
      outside_sandbox(fn ->
        Repo.delete_all(
          from(j in Oban.Job, where: fragment("?->>'source_id'", j.args) == ^workshop.id)
        )

        Repo.delete_all(from(e in Event, where: e.source_id == ^workshop.id))
        Repo.delete_all(from(w in Workshop, where: w.id == ^workshop.id))
        Repo.delete_all(from(r in UserRole, where: r.principal_id == ^staff))
        Repo.delete_all(from(mp in MemberProfile, where: mp.id == ^staff))
        Repo.delete_all(from(up in UserProfile, where: up.principal_id == ^staff))
        Repo.delete_all(from(p in Principal, where: p.id == ^staff))
      end)
    end)
  end
end
