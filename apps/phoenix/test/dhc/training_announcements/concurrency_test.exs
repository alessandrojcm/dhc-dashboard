defmodule Dhc.TrainingAnnouncements.ConcurrencyTest do
  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  alias Dhc.Auth.Principal
  alias Dhc.Auth.UserRole
  alias Dhc.ClubCalendar.Holiday
  alias Dhc.Discord.Adapter.Test, as: DiscordAdapter
  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Repo
  alias Dhc.TrainingAnnouncements
  alias Dhc.TrainingAnnouncements.Announcement
  alias Dhc.TrainingAnnouncements.DiscordAnnouncementDelivery
  alias Dhc.TrainingAnnouncements.Execution
  alias Dhc.TrainingAnnouncements.Workers.AnnouncementWorker
  alias Dhc.UserProfiles.UserProfile
  alias Ecto.Adapters.SQL.Sandbox

  test "a racing second driver does not repost or reinterpret an active message call" do
    supervisor = start_supervised!(Task.Supervisor)
    start_supervised!({DiscordAdapter, owner: self()})
    previous = Application.get_env(:dhc, :discord_sparring_channel_id)
    Application.put_env(:dhc, :discord_sparring_channel_id, "123456789012345678")
    on_exit(fn -> Application.put_env(:dhc, :discord_sparring_channel_id, previous) end)
    parent = self()

    DiscordAdapter.script(:create_message, [
      fn _ ->
        send(parent, {:posting, self()})

        receive do
          :continue -> {:ok, %{message_id: "234567890123456789"}}
        after
          5000 -> raise "message call was not released"
        end
      end
    ])

    DiscordAdapter.script(:create_thread_from_message, [{:ok, %{thread_id: "345678901234567890"}}])

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
          now: ~U[2030-09-05 09:00:00Z]
        )

      job = %Oban.Job{
        args: %{"announcement_id" => announcement.id, "occurrence_date" => "2030-09-05"},
        attempt: 1,
        max_attempts: 3
      }

      clock = Execution.clock(~U[2030-09-05 13:00:00.000000Z])

      try do
        task =
          Task.Supervisor.async_nolink(supervisor, fn ->
            Sandbox.unboxed_run(Repo, fn -> AnnouncementWorker.perform(job, clock: clock) end)
          end)

        assert_receive {:posting, caller}, 5000

        try do
          assert :ok = AnnouncementWorker.perform(%{job | attempt: 2}, clock: clock)

          assert [%{state: "posting_message"}] =
                   Repo.all(
                     from(d in DiscordAnnouncementDelivery,
                       where: d.announcement_id == ^announcement.id
                     )
                   )
        after
          send(caller, :continue)
        end

        assert :ok = Task.await(task, 10_000)

        assert [%{state: "delivered"}] =
                 Repo.all(
                   from(d in DiscordAnnouncementDelivery,
                     where: d.announcement_id == ^announcement.id
                   )
                 )

        assert_receive {:create_message, _}
        refute_receive {:create_message, _}
        assert_receive {:create_thread_from_message, _}
        refute_receive {:create_thread_from_message, _}
      after
        Repo.delete_all(from(a in Announcement, where: a.id == ^announcement.id))
        Repo.delete!(holiday)
        Repo.delete_all(from(j in Oban.Job, where: j.args["announcement_id"] == ^announcement.id))
        Repo.delete_all(from(r in UserRole, where: r.principal_id == ^actor))
        Repo.delete_all(from(m in MemberProfile, where: m.id == ^actor))
        Repo.delete_all(from(p in UserProfile, where: p.principal_id == ^actor))
        Repo.delete_all(from(p in Principal, where: p.id == ^actor))
      end
    end)
  end

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
