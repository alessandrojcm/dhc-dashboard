defmodule Dhc.TrainingAnnouncements.ConcurrencyTest do
  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  alias Dhc.Auth.Principal
  alias Dhc.Auth.UserRole
  alias Dhc.ClubCalendar.Holiday
  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Repo
  alias Dhc.TrainingAnnouncements
  alias Dhc.TrainingAnnouncements.Workers.AnnouncementWorker
  alias Dhc.UserProfiles.UserProfile
  alias Ecto.Adapters.SQL.Sandbox

  test "concurrent schedule edits commit the combined schedule and one matching driver" do
    supervisor = start_supervised!(Task.Supervisor)

    Sandbox.unboxed_run(Repo, fn ->
      member = Dhc.MemberFixtures.member_fixture()
      actor = member.principal_id
      Repo.insert!(%UserRole{principal_id: actor, role: "coach"})

      holiday =
        Repo.insert!(%Holiday{
          date: ~D[2030-01-01],
          name: "New Year",
          source_id: Ecto.UUID.generate(),
          fetched_at: DateTime.utc_now()
        })

      now = ~U[2030-09-05 09:00:00Z]

      {:ok, %{announcement: announcement}} =
        TrainingAnnouncements.create(
          actor,
          %{
            kind: "sparring",
            weekday: 4,
            post_time: ~T[14:00:00],
            title: "Training",
            message: "Come train",
            mention_everyone: false
          },
          now: now
        )

      try do
        parent = self()
        blocker = hold_row(supervisor, announcement.id, parent)
        assert_receive :row_held, 5000

        tasks =
          Enum.map([%{weekday: 5}, %{post_time: ~T[16:00:00]}], fn attrs ->
            Task.Supervisor.async_nolink(supervisor, fn ->
              Sandbox.unboxed_run(Repo, fn ->
                backend = Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()
                send(parent, {:ready, self(), backend})

                receive do
                  :go ->
                    TrainingAnnouncements.update_schedule(actor, announcement.id, attrs, now: now)
                end
              end)
            end)
          end)

        backends =
          Enum.map(tasks, fn task ->
            pid = task.pid
            assert_receive {:ready, ^pid, backend}, 5000
            backend
          end)

        try do
          Enum.each(tasks, &send(&1.pid, :go))
          # Establish competing snapshots, not merely concurrent task startup.
          # Both independent backends must be waiting on the held row before
          # release. Assertions below stay at the facade/job seam.
          await_blocked(backends, System.monotonic_time(:millisecond) + 5000)
        after
          send(blocker.pid, :release)
          Task.await(blocker, 10_000)
        end

        Enum.each(tasks, fn task -> assert {:ok, _} = Task.await(task, 10_000) end)

        assert {:ok, %{weekday: 5, post_time: ~T[16:00:00]}} =
                 TrainingAnnouncements.get(actor, announcement.id)

        assert [job] = all_enqueued(worker: AnnouncementWorker)
        assert job.args["occurrence_date"] == "2030-09-06"
        assert DateTime.compare(job.scheduled_at, ~U[2030-09-06 15:00:00Z]) == :eq
      after
        # These fixtures committed outside the sandbox. Teardown owns every row.
        TrainingAnnouncements.delete(actor, announcement.id)
        Repo.delete!(holiday)
        Repo.delete_all(from(r in UserRole, where: r.principal_id == ^actor))
        Repo.delete_all(from(m in MemberProfile, where: m.id == ^actor))
        Repo.delete_all(from(p in UserProfile, where: p.principal_id == ^actor))
        Repo.delete_all(from(p in Principal, where: p.id == ^actor))

        Repo.delete_all(
          from(j in Oban.Job,
            where: j.args["announcement_id"] == ^announcement.id
          )
        )
      end
    end)
  end

  defp hold_row(supervisor, id, parent) do
    Task.Supervisor.async_nolink(supervisor, fn ->
      Sandbox.unboxed_run(Repo, fn ->
        hold_transaction(id, parent)
      end)
    end)
  end

  defp hold_transaction(id, parent) do
    Repo.transaction(fn ->
      Repo.update_all(from(a in Dhc.TrainingAnnouncements.Announcement, where: a.id == ^id),
        set: [post_time: ~T[14:00:00]]
      )

      send(parent, :row_held)
      await_release()
    end)
  end

  defp await_release do
    receive do
      :release -> :ok
    end
  end

  defp await_blocked(backends, deadline) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE pid = ANY($1) AND wait_event_type = 'Lock'",
        [backends]
      )

    if count == 2 do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline,
             "both schedule edits must overlap on the held announcement row"

      await_blocked(backends, deadline)
    end
  end
end
