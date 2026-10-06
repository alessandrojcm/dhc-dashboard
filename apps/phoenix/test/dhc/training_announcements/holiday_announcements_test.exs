defmodule Dhc.TrainingAnnouncements.HolidayAnnouncementsTest do
  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  alias Dhc.Auth.UserRole
  alias Dhc.ClubCalendar.Holiday
  alias Dhc.Discord.Adapter.Test, as: DiscordAdapter
  alias Dhc.Discord.ApiError
  alias Dhc.Repo
  alias Dhc.TrainingAnnouncements
  alias Dhc.TrainingAnnouncements.DiscordAnnouncementDelivery, as: Evidence
  alias Dhc.TrainingAnnouncements.Execution
  alias Dhc.TrainingAnnouncements.Workers.AnnouncementWorker
  alias Dhc.TrainingAnnouncements.Workers.HolidayAnnouncementWorker

  setup do
    start_supervised!({DiscordAdapter, owner: self()})
    member = Dhc.MemberFixtures.member_fixture()
    Repo.insert!(%UserRole{principal_id: member.principal_id, role: "coach"})

    Repo.insert!(%Holiday{
      date: ~D[2030-08-05],
      name: "August Bank Holiday",
      source_id: "august",
      fetched_at: DateTime.utc_now()
    })

    previous = Application.get_env(:dhc, :discord_training_announcements_channel_id)
    Application.put_env(:dhc, :discord_training_announcements_channel_id, "123456789012345678")

    on_exit(fn ->
      Application.put_env(:dhc, :discord_training_announcements_channel_id, previous)
    end)

    %{actor: member.principal_id}
  end

  test "a holiday roll call records its skip and delivers the same-day reminder without a thread",
       ctx do
    announcement = create(ctx)
    DiscordAdapter.script(:create_message, [{:ok, %{message_id: "234567890123456789"}}])
    assert :ok = run(announcement)

    assert [%{state: "skipped", reason: "holiday"}] =
             Repo.all(from(d in Evidence, where: d.subject == "occurrence"))

    assert [
             %{
               state: "delivered",
               holiday_date: ~D[2030-08-05],
               phase: "same_day",
               mention_everyone: true,
               discord_thread_id: nil,
               concluded_at: at
             }
           ] = holidays()

    assert at != nil

    assert_receive {:create_message,
                    [
                      "123456789012345678",
                      %{
                        content:
                          "@everyone\n⚠️ Reminder @everyone: Today is August Bank Holiday (a bank holiday), so there will be no training. See you next time! 🎉",
                        allowed_mentions: %{parse: ["everyone"]}
                      }
                    ]}

    refute_receive {:create_thread_from_message, _}
    assert :ok = run(announcement)
    assert [_] = holidays()
    refute_receive {:create_message, _}
  end

  test "two roll calls share a day-before driver at Dublin post time and one post per phase",
       ctx do
    first = create(ctx)
    second = create(ctx)
    assert [job] = all_enqueued(worker: HolidayAnnouncementWorker)
    assert DateTime.compare(job.scheduled_at, ~U[2030-08-04 13:00:00Z]) == :eq
    assert job.args == %{"holiday_date" => "2030-08-05", "phase" => "day_before"}

    DiscordAdapter.script(:create_message, [
      {:ok, %{message_id: "234567890123456789"}},
      {:ok, %{message_id: "345678901234567890"}}
    ])

    assert :ok =
             HolidayAnnouncementWorker.perform(%{job | attempt: 1},
               clock: Execution.clock(~U[2030-08-04 13:00:00.000000Z])
             )

    assert :ok = run(first)
    assert :ok = run(second)

    assert Enum.sort(Enum.map(holidays(), &{&1.phase, &1.state})) == [
             {"day_before", "delivered"},
             {"same_day", "delivered"}
           ]

    assert_receive {:create_message,
                    [
                      _,
                      %{
                        content:
                          "@everyone\n⚠️ Heads up @everyone! Tomorrow is August Bank Holiday (a bank holiday), so there will be no training. Enjoy your day off! 🎉"
                      }
                    ]}

    assert_receive {:create_message, _}
    refute_receive {:create_message, _}
    refute_receive {:create_thread_from_message, _}
  end

  test "day-before rechecks a changed post time instead of losing the heads-up", ctx do
    announcement = create(ctx)
    assert [job] = all_enqueued(worker: HolidayAnnouncementWorker)

    assert {:ok, _} =
             TrainingAnnouncements.update_schedule(
               ctx.actor,
               announcement.id,
               %{weekday: 1, post_time: ~T[16:00:00]},
               now: ~U[2030-08-02 12:00:00Z]
             )

    assert {:snooze, 7200} =
             HolidayAnnouncementWorker.perform(%{job | attempt: 1},
               clock: Execution.clock(~U[2030-08-04 13:00:00.000000Z])
             )

    assert holidays() == []
    DiscordAdapter.script(:create_message, [{:ok, %{message_id: "234567890123456789"}}])

    assert :ok =
             HolidayAnnouncementWorker.perform(%{job | attempt: 1},
               clock: Execution.clock(~U[2030-08-04 15:00:00.000000Z])
             )

    assert [%{state: "delivered", post_time: ~T[16:00:00]}] = holidays()
  end

  test "a schedule edit to an earlier post time moves the shared day-before job", ctx do
    announcement = create(ctx)

    assert {:ok, _} =
             TrainingAnnouncements.update_schedule(
               ctx.actor,
               announcement.id,
               %{weekday: 1, post_time: ~T[12:00:00]},
               now: ~U[2030-08-02 12:00:00Z]
             )

    assert [job] = all_enqueued(worker: HolidayAnnouncementWorker)
    assert DateTime.compare(job.scheduled_at, ~U[2030-08-04 11:00:00Z]) == :eq
  end

  test "an elapsed day-before is never scheduled but the same-day reminder still posts", ctx do
    announcement = create(ctx, %{}, ~U[2030-08-04 13:00:00Z])
    assert all_enqueued(worker: HolidayAnnouncementWorker) == []
    DiscordAdapter.script(:create_message, [{:ok, %{message_id: "234567890123456789"}}])
    assert :ok = run(announcement)
    assert [%{phase: "same_day", state: "delivered"}] = holidays()
  end

  test "a late cache correction still suppresses the roll call and sends today's reminder", ctx do
    Repo.delete_all(Holiday)

    Repo.insert!(%Holiday{
      date: ~D[2030-01-01],
      name: "New Year",
      source_id: "new-year",
      fetched_at: DateTime.utc_now()
    })

    announcement = create(ctx)
    assert all_enqueued(worker: HolidayAnnouncementWorker) == []

    Repo.insert!(%Holiday{
      date: ~D[2030-08-05],
      name: "August Bank Holiday",
      source_id: "august",
      fetched_at: DateTime.utc_now()
    })

    DiscordAdapter.script(:create_message, [{:ok, %{message_id: "234567890123456789"}}])
    assert :ok = run(announcement)
    assert [%{phase: "same_day", state: "delivered"}] = holidays()

    assert [%{reason: "holiday", state: "skipped"}] =
             Repo.all(from(d in Evidence, where: d.subject == "occurrence"))
  end

  test "all disabled roll calls suppress both phases without losing the occurrence's holiday skip",
       ctx do
    first = create(ctx)
    second = create(ctx)
    {:ok, _} = TrainingAnnouncements.disable(ctx.actor, first.id)
    {:ok, _} = TrainingAnnouncements.disable(ctx.actor, second.id)
    assert [job] = all_enqueued(worker: HolidayAnnouncementWorker)
    assert :ok = run_day_before(job)
    assert :ok = run(first)
    assert :ok = run(second)
    assert holidays() == []

    assert [_, _] =
             Repo.all(from(d in Evidence, where: d.state == "skipped" and d.reason == "holiday"))

    refute_receive {:create_message, _}
  end

  test "day-before rechecks the holiday cache and current occurrence after a schedule edit",
       ctx do
    announcement = create(ctx)
    assert [job] = all_enqueued(worker: HolidayAnnouncementWorker)

    {:ok, _} =
      TrainingAnnouncements.update_schedule(
        ctx.actor,
        announcement.id,
        %{weekday: 2, post_time: ~T[14:00:00]},
        now: ~U[2030-08-02 12:00:00Z]
      )

    assert :ok = run_day_before(job)
    assert holidays() == []

    {:ok, _} =
      TrainingAnnouncements.update_schedule(
        ctx.actor,
        announcement.id,
        %{weekday: 1, post_time: ~T[14:00:00]},
        now: ~U[2030-08-02 12:00:00Z]
      )

    Repo.delete_all(from(h in Holiday, where: h.date == ^~D[2030-08-05]))

    Repo.insert!(%Holiday{
      date: ~D[2030-01-01],
      name: "New Year",
      source_id: "new-year",
      fetched_at: DateTime.utc_now()
    })

    assert :ok = run_day_before(job)
    assert holidays() == []
    refute_receive {:create_message, _}
  end

  test "exceptions do not prevent holiday reminders", ctx do
    announcement = create(ctx)

    assert {:ok, _} =
             TrainingAnnouncements.suppress(
               ctx.actor,
               announcement.id,
               %{from_date: ~D[2030-08-05], to_date: ~D[2030-08-05]},
               now: ~U[2030-08-01 12:00:00Z]
             )

    assert {:ok, _} =
             TrainingAnnouncements.override(
               ctx.actor,
               announcement.id,
               %{from_date: ~D[2030-08-05], to_date: ~D[2030-08-05], message: "Special training"},
               now: ~U[2030-08-01 12:00:00Z]
             )

    DiscordAdapter.script(:create_message, [{:ok, %{message_id: "234567890123456789"}}])
    assert :ok = run(announcement)
    assert [%{state: "delivered"}] = holidays()
  end

  test "sparring on a holiday posts normally and creates no holiday driver or reminder", ctx do
    previous = Application.get_env(:dhc, :discord_sparring_channel_id)
    Application.put_env(:dhc, :discord_sparring_channel_id, "123456789012345678")
    on_exit(fn -> Application.put_env(:dhc, :discord_sparring_channel_id, previous) end)
    announcement = create(ctx, %{kind: "sparring"})
    assert all_enqueued(worker: HolidayAnnouncementWorker) == []
    DiscordAdapter.script(:create_message, [{:ok, %{message_id: "234567890123456789"}}])

    DiscordAdapter.script(:create_thread_from_message, [{:ok, %{thread_id: "345678901234567890"}}])

    assert :ok = run(announcement)
    assert holidays() == []
    assert [%{state: "delivered", subject: "occurrence"}] = Repo.all(Evidence)
  end

  test "missing holiday channel blocks before freeze and reports once while preserving the roll-call skip",
       ctx do
    Sentry.Test.setup_sentry()
    Application.delete_env(:dhc, :discord_training_announcements_channel_id)
    announcement = create(ctx)
    assert :ok = run(announcement)

    assert [
             %{
               state: "blocked",
               reason: "unconfigured_channel",
               frozen_at: nil,
               message_source: nil,
               concluded_at: at
             }
           ] = holidays()

    assert at != nil

    assert [%Sentry.Event{extra: %{reason: "unconfigured_channel"}}] =
             Sentry.Test.pop_sentry_reports()

    assert :ok = run(announcement)
    assert Sentry.Test.pop_sentry_reports() == []

    assert [%{state: "skipped", reason: "holiday"}] =
             Repo.all(from(d in Evidence, where: d.subject == "occurrence"))

    assert {:ok, %{first_attempted_at: nil}} =
             TrainingAnnouncements.get(ctx.actor, announcement.id)

    refute_receive {:create_message, _}
  end

  for {status, state, reason} <- [
        {403, "blocked", "permission"},
        {408, "message_uncertain", "timeout"}
      ] do
    test "holiday transport #{status} is terminal evidence and never reposts", ctx do
      Sentry.Test.setup_sentry()
      announcement = create(ctx)

      DiscordAdapter.script(:create_message, [
        {:error, %ApiError{status: unquote(status), message: "Failure"}}
      ])

      assert :ok = run(announcement)

      assert [
               %{
                 state: unquote(state),
                 reason: unquote(reason),
                 discord_thread_id: nil,
                 error_detail: ": Failure",
                 concluded_at: at
               }
             ] = holidays()

      assert at != nil
      assert [%Sentry.Event{}] = Sentry.Test.pop_sentry_reports()
      assert_receive {:create_message, _}
      assert :ok = run(announcement)
      refute_receive {:create_message, _}
      refute_receive {:create_thread_from_message, _}
    end
  end

  test "a lost holiday worker after submission becomes uncertain without reposting", ctx do
    Sentry.Test.setup_sentry()
    announcement = create(ctx)
    DiscordAdapter.script(:create_message, [fn _ -> exit(:worker_crashed) end])
    assert catch_exit(run(announcement)) == :worker_crashed
    assert_receive {:create_message, _}
    assert :ok = run(announcement)
    assert [%{state: "message_uncertain", reason: "worker_lost"}] = holidays()
    assert [%Sentry.Event{}] = Sentry.Test.pop_sentry_reports()
    refute_receive {:create_message, _}
  end

  test "a definitive message retry retains frozen holiday copy and destination", ctx do
    announcement = create(ctx)
    error = %ApiError{status: 429, message: "Rate limited"}

    DiscordAdapter.script(:create_message, [
      {:error, error},
      {:ok, %{message_id: "234567890123456789"}}
    ])

    assert {:error, {:rate_limited, ": Rate limited"}} = run(announcement)
    assert [frozen] = holidays()
    assert frozen.state == "frozen"
    assert_receive {:create_message, [channel, params]}
    Application.delete_env(:dhc, :discord_training_announcements_channel_id)
    {:ok, _} = TrainingAnnouncements.disable(ctx.actor, announcement.id)
    assert :ok = run(announcement, attempt: 2)
    assert_receive {:create_message, [^channel, ^params]}
    assert [%{state: "delivered", frozen_at: at}] = holidays()
    assert at == frozen.frozen_at
    refute_receive {:create_thread_from_message, _}
  end

  test "an overdue day-before job records missed evidence instead of posting on the holiday date",
       ctx do
    create(ctx)
    assert [job] = all_enqueued(worker: HolidayAnnouncementWorker)

    assert :ok =
             HolidayAnnouncementWorker.perform(%{job | attempt: 1},
               clock: Execution.clock(~U[2030-08-05 13:00:00.000000Z])
             )

    assert [
             %{
               state: "missed",
               reason: "late",
               phase: "day_before",
               frozen_at: nil,
               concluded_at: at
             }
           ] = holidays()

    assert at != nil
    refute_receive {:create_message, _}
  end

  test "an elapsed disabled slot does not hide a still-future enabled heads-up", ctx do
    earlier = create(ctx, %{post_time: ~T[12:00:00]})
    {:ok, _} = TrainingAnnouncements.disable(ctx.actor, earlier.id)
    # The engine has consumed the earlier driver; a new announcement still
    # needs its future day-before slot, not that elapsed disabled slot.
    Repo.update_all(
      from(j in Oban.Job, where: j.worker == ^Oban.Worker.to_string(HolidayAnnouncementWorker)),
      set: [state: "completed"]
    )

    create(ctx, %{post_time: ~T[16:00:00]}, ~U[2030-08-04 12:00:00Z])
    assert [job] = all_enqueued(worker: HolidayAnnouncementWorker)
    assert DateTime.compare(job.scheduled_at, ~U[2030-08-04 15:00:00Z]) == :eq
    DiscordAdapter.script(:create_message, [{:ok, %{message_id: "234567890123456789"}}])

    assert :ok =
             HolidayAnnouncementWorker.perform(%{job | attempt: 1},
               clock: Execution.clock(~U[2030-08-04 15:00:00.000000Z])
             )

    assert [%{state: "delivered", post_time: ~T[16:00:00]}] = holidays()
  end

  test "deleting the roll call cannot strand a frozen same-day reminder", ctx do
    announcement = create(ctx)
    error = %ApiError{status: 429, message: "Rate limited"}

    DiscordAdapter.script(:create_message, [
      {:error, error},
      {:ok, %{message_id: "234567890123456789"}}
    ])

    assert {:error, {:rate_limited, ": Rate limited"}} = run(announcement)

    assert [job] =
             Enum.filter(
               all_enqueued(worker: HolidayAnnouncementWorker),
               &(&1.args["phase"] == "same_day")
             )

    assert {:ok, _} = TrainingAnnouncements.delete(ctx.actor, announcement.id)
    assert Enum.any?(all_enqueued(worker: HolidayAnnouncementWorker), &(&1.id == job.id))

    assert :ok =
             HolidayAnnouncementWorker.perform(%{job | attempt: 1},
               clock: Execution.clock(~U[2030-08-05 13:01:00.000000Z])
             )

    assert [%{state: "delivered", phase: "same_day"}] = holidays()
  end

  test "retiring a roll call cannot strand a lost holiday submission", ctx do
    Sentry.Test.setup_sentry()
    announcement = create(ctx)
    DiscordAdapter.script(:create_message, [fn _ -> exit(:worker_crashed) end])
    assert catch_exit(run(announcement)) == :worker_crashed
    assert_receive {:create_message, _}
    assert {:ok, _} = TrainingAnnouncements.retire(ctx.actor, announcement.id)

    assert [job] =
             Enum.filter(
               all_enqueued(worker: HolidayAnnouncementWorker),
               &(&1.args["phase"] == "same_day")
             )

    assert :ok =
             HolidayAnnouncementWorker.perform(%{job | attempt: 1},
               clock: Execution.clock(~U[2030-08-05 13:01:00.000000Z])
             )

    assert [%{state: "message_uncertain", reason: "worker_lost"}] = holidays()
    assert [%Sentry.Event{}] = Sentry.Test.pop_sentry_reports()
    refute_receive {:create_message, _}
  end

  test "overlapping roll-call and recovery drivers keep one live holiday submission", ctx do
    first = create(ctx)
    second = create(ctx)
    owner = self()
    supervisor = start_supervised!(Task.Supervisor)

    DiscordAdapter.script(:create_message, [
      fn _ ->
        send(owner, {:posting, self()})

        receive do
          :finish_post -> {:ok, %{message_id: "234567890123456789"}}
        after
          5000 -> raise "test did not release the Discord call"
        end
      end
    ])

    task = Task.Supervisor.async_nolink(supervisor, fn -> run(first) end)
    assert_receive {:posting, worker}
    assert_receive {:create_message, _}
    assert {:snooze, 30} = run(second)

    assert [job] =
             Enum.filter(
               all_enqueued(worker: HolidayAnnouncementWorker),
               &(&1.args["phase"] == "same_day")
             )

    assert {:snooze, 30} =
             HolidayAnnouncementWorker.perform(%{job | attempt: 1},
               clock: Execution.clock(~U[2030-08-05 13:01:00.000000Z])
             )

    send(worker, :finish_post)
    assert :ok = Task.await(task)
    assert :ok = run(second)
    assert [%{state: "delivered"}] = holidays()
    refute_receive {:create_message, _}
    refute_receive {:create_thread_from_message, _}
  end

  defp run_day_before(job),
    do:
      HolidayAnnouncementWorker.perform(%{job | attempt: 1},
        clock: Execution.clock(~U[2030-08-04 13:00:00.000000Z])
      )

  defp create(ctx, extra \\ %{}, now \\ ~U[2030-08-01 12:00:00Z]) do
    {:ok, %{announcement: announcement}} =
      TrainingAnnouncements.create(
        ctx.actor,
        Map.merge(
          %{
            kind: "roll_call",
            weekday: 1,
            post_time: ~T[14:00:00],
            title: "Roll call",
            message: "Come train",
            mention_everyone: false
          },
          extra
        ),
        now: now
      )

    announcement
  end

  defp run(announcement, opts \\ []) do
    AnnouncementWorker.perform(
      %Oban.Job{
        args: %{"announcement_id" => announcement.id, "occurrence_date" => "2030-08-05"},
        attempt: Keyword.get(opts, :attempt, 1),
        max_attempts: 4
      },
      clock: Execution.clock(~U[2030-08-05 13:00:00.000000Z])
    )
  end

  defp holidays, do: Repo.all(from(d in Evidence, where: d.subject == "holiday"))
end
