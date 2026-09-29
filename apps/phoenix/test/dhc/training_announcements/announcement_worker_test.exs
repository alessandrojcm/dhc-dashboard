defmodule Dhc.TrainingAnnouncements.AnnouncementWorkerTest do
  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  alias Dhc.Auth.UserRole
  alias Dhc.ClubCalendar
  alias Dhc.ClubCalendar.Holiday
  alias Dhc.Discord.Adapter.Test, as: DiscordAdapter
  alias Dhc.Discord.ApiError
  alias Dhc.Repo
  alias Dhc.TrainingAnnouncements
  alias Dhc.TrainingAnnouncements.Announcement
  alias Dhc.TrainingAnnouncements.DiscordAnnouncementDelivery
  alias Dhc.TrainingAnnouncements.Workers.AnnouncementWorker

  setup do
    start_supervised!({DiscordAdapter, owner: self()})
    member = Dhc.MemberFixtures.member_fixture()
    Repo.insert!(%UserRole{principal_id: member.principal_id, role: "coach"})
    today = ~D[2030-09-05]

    Repo.insert!(%Holiday{
      date: Date.new!(today.year, 1, 1),
      name: "New Year",
      source_id: "new-year",
      fetched_at: DateTime.utc_now()
    })

    %{actor: member.principal_id, today: today}
  end

  test "a disabled due occurrence is recorded once and advances the weekly schedule", ctx do
    announcement = create_due(ctx)
    {:ok, _} = TrainingAnnouncements.disable(ctx.actor, announcement.id)
    assert :ok = perform_due(args(announcement, ctx.today))

    assert [%{state: "skipped", reason: "disabled", concluded_at: at, frozen_at: nil}] =
             deliveries()

    assert at != nil
    assert [next] = all_enqueued(worker: AnnouncementWorker)
    assert next.args["occurrence_date"] == Date.to_iso8601(Date.add(ctx.today, 7))
    assert DateTime.compare(next.scheduled_at, ~U[2030-09-05 13:00:00Z]) == :gt
    assert :ok = perform_due(args(announcement, ctx.today))
    assert [_] = deliveries()

    assert {:ok, %{first_attempted_at: nil}} =
             TrainingAnnouncements.get(ctx.actor, announcement.id)

    assert {:ok, _} = TrainingAnnouncements.delete(ctx.actor, announcement.id)
    assert deliveries() == []
  end

  test "a bank holiday outranks disablement at run time", ctx do
    Repo.insert!(%Holiday{
      date: ctx.today,
      name: "Bank holiday",
      source_id: "today",
      fetched_at: DateTime.utc_now()
    })

    announcement = create_due(ctx, %{kind: "roll_call"})
    {:ok, _} = TrainingAnnouncements.disable(ctx.actor, announcement.id)
    assert :ok = perform_due(args(announcement, ctx.today))
    assert [%{state: "skipped", reason: "holiday"}] = deliveries()
  end

  test "yesterday is missed even when disabled; a one-off stops", ctx do
    yesterday = Date.add(ctx.today, -1)
    announcement = create_due(%{ctx | today: yesterday}, %{weekday: nil, one_off_date: yesterday})
    {:ok, _} = TrainingAnnouncements.disable(ctx.actor, announcement.id)
    # perform_job does not consume the persisted job; mark it executing as the
    # Oban engine would, so the observable pending set reflects a real run.
    Repo.update_all(from(j in Oban.Job, where: j.args["announcement_id"] == ^announcement.id),
      set: [state: "executing"]
    )

    assert :ok = perform_due(args(announcement, yesterday))
    assert [%{state: "missed", reason: "late", concluded_at: at}] = deliveries()
    assert at != nil
    assert all_enqueued(worker: AnnouncementWorker) == []
  end

  test "unconfigured routing blocks before freeze, emits Sentry and stays deletable", ctx do
    Sentry.Test.setup_sentry()
    previous = Application.get_env(:dhc, :discord_sparring_channel_id)
    Application.delete_env(:dhc, :discord_sparring_channel_id)
    on_exit(fn -> Application.put_env(:dhc, :discord_sparring_channel_id, previous) end)
    announcement = create_due(ctx)
    assert :ok = perform_due(args(announcement, ctx.today))

    assert [
             %{
               state: "blocked",
               reason: "unconfigured_channel",
               frozen_at: nil,
               channel_id: nil,
               title_source: nil,
               rendered_message: nil,
               concluded_at: at
             }
           ] = deliveries()

    assert at != nil

    assert [%Sentry.Event{extra: %{reason: "unconfigured_channel"}}] =
             Sentry.Test.pop_sentry_reports()

    assert :ok = perform_due(args(announcement, ctx.today))
    assert Sentry.Test.pop_sentry_reports() == []
    assert {:ok, _} = TrainingAnnouncements.delete(ctx.actor, announcement.id)
  end

  test "invalid resolved copy blocks before freeze",
       ctx do
    Sentry.Test.setup_sentry()
    previous = Application.get_env(:dhc, :discord_sparring_channel_id)
    Application.put_env(:dhc, :discord_sparring_channel_id, "123456789012345678")
    on_exit(fn -> Application.put_env(:dhc, :discord_sparring_channel_id, previous) end)
    announcement = create_due(ctx)
    # Persist corrupt legacy copy to exercise the worker's validation fence.
    Repo.update_all(from(a in Announcement, where: a.id == ^announcement.id),
      set: [message: "{{unsupported}}"]
    )

    assert :ok = perform_due(args(announcement, ctx.today))
    assert [%{state: "blocked", reason: "invalid_copy", frozen_at: nil}] = deliveries()
    assert [%Sentry.Event{extra: %{reason: "invalid_copy"}}] = Sentry.Test.pop_sentry_reports()
  end

  test "a due occurrence posts once with frozen copy and a thread", ctx do
    configure_channel()
    DiscordAdapter.script(:create_message, [{:ok, %{message_id: "234567890123456789"}}])

    DiscordAdapter.script(:create_thread_from_message, [{:ok, %{thread_id: "345678901234567890"}}])

    announcement = create_due(ctx, %{title: "Training {{weekday}}", mention_everyone: true})

    assert :ok = perform_due(args(announcement, ctx.today))
    assert [delivery] = deliveries()
    assert delivery.state == "delivered"
    assert delivery.discord_message_id == "234567890123456789"
    assert delivery.discord_thread_id == "345678901234567890"
    assert delivery.title_source == "Training {{weekday}}"
    assert delivery.thread_name == "Training Thursday"
    assert delivery.rendered_message == "@everyone\nCome train"
    assert delivery.post_time == announcement.post_time
    assert delivery.thread_attempts == 1

    for field <- [
          :frozen_at,
          :posting_started_at,
          :message_posted_at,
          :thread_created_at,
          :concluded_at
        ],
        do: assert(Map.fetch!(delivery, field) != nil)

    assert_receive {:create_message,
                    [
                      "123456789012345678",
                      %{
                        content: "@everyone\nCome train",
                        allowed_mentions: %{parse: ["everyone"]},
                        nonce: nonce
                      }
                    ]}

    assert is_binary(nonce)

    assert_receive {:create_thread_from_message,
                    [
                      "123456789012345678",
                      "234567890123456789",
                      %{name: "Training Thursday", auto_archive_duration: 1440}
                    ]}

    assert {:ok, %{first_attempted_at: at}} =
             TrainingAnnouncements.get(ctx.actor, announcement.id)

    assert at == delivery.frozen_at
    assert :ok = perform_due(args(announcement, ctx.today))
    refute_receive {:create_message, _}
    assert [_] = deliveries()
    Repo.delete!(delivery)
    assert {:error, :attempted} = TrainingAnnouncements.delete(ctx.actor, announcement.id)
  end

  for {status, state, reason} <- [
        {403, "blocked", "permission"},
        {404, "blocked", "unknown_channel"},
        {400, "blocked", "payload_rejected"},
        {408, "message_uncertain", "timeout"},
        {503, "message_uncertain", "server_error"}
      ] do
    test "Discord #{status} retains #{state} evidence without reposting", ctx do
      configure_channel()
      Sentry.Test.setup_sentry()

      DiscordAdapter.script(:create_message, [
        {:error,
         %ApiError{status: unquote(status), code: 123, message: String.duplicate("x", 600)}}
      ])

      announcement = create_due(ctx)
      assert :ok = perform_due(args(announcement, ctx.today))
      assert [delivery] = deliveries()
      assert delivery.state == unquote(state)
      assert delivery.reason == unquote(reason)
      assert delivery.concluded_at != nil
      assert String.length(delivery.error_detail) == 500
      assert String.starts_with?(delivery.error_detail, "123:")
      assert_receive {:create_message, [_, %{allowed_mentions: %{parse: []}}]}
      assert [%Sentry.Event{extra: %{reason: unquote(reason)}}] = Sentry.Test.pop_sentry_reports()
      assert :ok = perform_due(args(announcement, ctx.today))
      refute_receive {:create_message, _}
      refute_receive {:create_thread_from_message, _}
      assert Sentry.Test.pop_sentry_reports() == []
    end
  end

  test "a lost posting worker never reposts the committed message attempt", ctx do
    configure_channel()
    Sentry.Test.setup_sentry()
    announcement = create_due(ctx)

    DiscordAdapter.script(:create_message, [
      fn _args ->
        refute Repo.in_transaction?()
        assert [%{state: "posting_message", posting_started_at: at}] = deliveries()
        assert at != nil
        exit(:worker_crashed)
      end
    ])

    assert catch_exit(perform_due(args(announcement, ctx.today), attempt: 3)) == :worker_crashed
    assert_receive {:create_message, _}
    assert :ok = perform_due(args(announcement, ctx.today), attempt: 4)
    assert [%{state: "message_uncertain", reason: "worker_lost", concluded_at: at}] = deliveries()
    assert at != nil
    assert [%Sentry.Event{extra: %{reason: "worker_lost"}}] = Sentry.Test.pop_sentry_reports()
    refute_receive {:create_message, _}
    refute_receive {:create_thread_from_message, _}
  end

  test "thread rejection retries without reposting, then retains the standing message", ctx do
    configure_channel()
    Sentry.Test.setup_sentry()
    announcement = create_due(ctx)
    DiscordAdapter.script(:create_message, [{:ok, %{message_id: "234567890123456789"}}])
    error = %ApiError{status: 403, code: 50_013, message: "Missing permissions"}
    DiscordAdapter.script(:create_thread_from_message, List.duplicate({:error, error}, 3))

    for attempt <- 1..2 do
      assert {:error, ^error} = perform_due(args(announcement, ctx.today), attempt: attempt)

      assert [
               %{
                 state: "message_posted",
                 thread_attempts: ^attempt,
                 discord_message_id: "234567890123456789",
                 last_thread_error: "50013: Missing permissions"
               }
             ] = deliveries()

      assert Sentry.Test.pop_sentry_reports() == []
    end

    assert :ok = perform_due(args(announcement, ctx.today), attempt: 3)

    assert [
             %{
               state: "thread_failed",
               reason: "permission",
               thread_attempts: 3,
               concluded_at: at,
               discord_message_id: "234567890123456789"
             }
           ] = deliveries()

    assert at != nil
    assert_receive {:create_message, _}
    refute_receive {:create_message, _}
    for _ <- 1..3, do: assert_receive({:create_thread_from_message, _})
    assert [%Sentry.Event{extra: %{reason: "permission"}}] = Sentry.Test.pop_sentry_reports()
    assert :ok = perform_due(args(announcement, ctx.today), attempt: 3)
    refute_receive {:create_thread_from_message, _}
  end

  test "a definitive message deferral retries the same frozen payload and nonce after edits",
       ctx do
    configure_channel()
    announcement = create_due(ctx)
    error = %ApiError{status: 429, message: "Rate limited"}

    DiscordAdapter.script(:create_message, [
      {:error, error},
      {:ok, %{message_id: "234567890123456789"}}
    ])

    DiscordAdapter.script(:create_thread_from_message, [{:ok, %{thread_id: "345678901234567890"}}])

    assert {:error, ^error} = perform_due(args(announcement, ctx.today))
    assert [frozen] = deliveries()
    assert frozen.state == "frozen"
    assert frozen.posting_started_at != nil
    assert_receive {:create_message, [channel, params]}

    assert {:ok, _} =
             TrainingAnnouncements.update_copy(ctx.actor, announcement.id, %{
               title: "Changed",
               message: "Changed",
               mention_everyone: true
             })

    assert {:ok, _} =
             TrainingAnnouncements.update_schedule(
               ctx.actor,
               announcement.id,
               %{weekday: 5, post_time: ~T[16:00:00]},
               now: ~U[2030-09-05 13:00:00Z]
             )

    assert {:ok, _} = TrainingAnnouncements.disable(ctx.actor, announcement.id)
    assert :ok = perform_due(args(announcement, ctx.today), attempt: 2)
    assert_receive {:create_message, [^channel, ^params]}
    assert [delivered] = deliveries()
    assert delivered.state == "delivered"
    assert delivered.title_source == frozen.title_source
    assert delivered.message_source == frozen.message_source
    assert delivered.post_time == frozen.post_time
    assert delivered.frozen_at == frozen.frozen_at

    assert {:ok, %{first_attempted_at: at}} =
             TrainingAnnouncements.get(ctx.actor, announcement.id)

    assert at == frozen.frozen_at
  end

  test "a thread retry can succeed while preserving its failure evidence", ctx do
    configure_channel()
    announcement = create_due(ctx)
    error = %ApiError{status: 429, message: "Rate limited"}
    DiscordAdapter.script(:create_message, [{:ok, %{message_id: "234567890123456789"}}])

    DiscordAdapter.script(:create_thread_from_message, [
      {:error, error},
      {:ok, %{thread_id: "345678901234567890"}}
    ])

    assert {:error, ^error} = perform_due(args(announcement, ctx.today))
    assert :ok = perform_due(args(announcement, ctx.today), attempt: 2)

    assert [%{state: "delivered", thread_attempts: 2, last_thread_error: ": Rate limited"}] =
             deliveries()

    assert_receive {:create_message, _}
    refute_receive {:create_message, _}
  end

  test "an uncertain thread result is terminal and never reposts or retries", ctx do
    configure_channel()
    Sentry.Test.setup_sentry()
    announcement = create_due(ctx)
    DiscordAdapter.script(:create_message, [{:ok, %{message_id: "234567890123456789"}}])

    DiscordAdapter.script(:create_thread_from_message, [
      {:error, %ApiError{status: 408, message: "Timeout"}}
    ])

    assert :ok = perform_due(args(announcement, ctx.today))

    assert [
             %{
               state: "thread_failed",
               reason: "timeout",
               discord_message_id: "234567890123456789",
               thread_attempts: 1
             }
           ] = deliveries()

    assert [%Sentry.Event{}] = Sentry.Test.pop_sentry_reports()
    assert_receive {:create_message, _}
    assert_receive {:create_thread_from_message, _}
    assert :ok = perform_due(args(announcement, ctx.today), attempt: 2)
    refute_receive {:create_message, _}
    refute_receive {:create_thread_from_message, _}
  end

  test "a lost thread worker retains the message as terminal evidence", ctx do
    configure_channel()
    Sentry.Test.setup_sentry()
    announcement = create_due(ctx)
    DiscordAdapter.script(:create_message, [{:ok, %{message_id: "234567890123456789"}}])
    DiscordAdapter.script(:create_thread_from_message, [fn _ -> exit(:worker_crashed) end])
    assert catch_exit(perform_due(args(announcement, ctx.today), attempt: 3)) == :worker_crashed
    assert_receive {:create_message, _}
    assert_receive {:create_thread_from_message, _}
    assert :ok = perform_due(args(announcement, ctx.today), attempt: 4)

    assert [
             %{
               state: "thread_failed",
               reason: "worker_lost",
               discord_message_id: "234567890123456789",
               thread_attempts: 1,
               last_thread_error: detail
             }
           ] = deliveries()

    assert detail != nil
    assert [%Sentry.Event{}] = Sentry.Test.pop_sentry_reports()
    refute_receive {:create_message, _}
    refute_receive {:create_thread_from_message, _}
  end

  test "the final driver attempt is reserved for evidence, never a new Discord call", ctx do
    configure_channel()
    Sentry.Test.setup_sentry()
    announcement = create_due(ctx)
    assert :ok = perform_due(args(announcement, ctx.today), attempt: 4)
    assert [%{state: "blocked", reason: "unknown", concluded_at: at}] = deliveries()
    assert at != nil
    assert [%Sentry.Event{}] = Sentry.Test.pop_sentry_reports()
    refute_receive {:create_message, _}
    refute_receive {:create_thread_from_message, _}
  end

  test "a deferred message is missed rather than sent on the next Dublin date", ctx do
    configure_channel()
    announcement = create_due(ctx)
    error = %ApiError{status: 429, message: "Rate limited"}
    DiscordAdapter.script(:create_message, [{:error, error}])
    assert {:error, ^error} = perform_due(args(announcement, ctx.today))
    assert_receive {:create_message, _}

    assert :ok =
             perform_due(args(announcement, ctx.today),
               attempt: 2,
               clock: fn -> ~U[2030-09-06 00:00:00.000000Z] end
             )

    assert [%{state: "missed", reason: "late", concluded_at: at}] = deliveries()
    assert at != nil
    refute_receive {:create_message, _}
  end

  test "a later weekly freeze never replaces the first attempted stamp", ctx do
    configure_channel()
    announcement = create_due(ctx)

    DiscordAdapter.script(:create_message, [
      {:ok, %{message_id: "234567890123456789"}},
      {:ok, %{message_id: "456789012345678901"}}
    ])

    DiscordAdapter.script(:create_thread_from_message, [
      {:ok, %{thread_id: "345678901234567890"}},
      {:ok, %{thread_id: "567890123456789012"}}
    ])

    assert :ok = perform_due(args(announcement, ctx.today))

    assert {:ok, %{first_attempted_at: first}} =
             TrainingAnnouncements.get(ctx.actor, announcement.id)

    assert :ok =
             perform_due(args(announcement, Date.add(ctx.today, 7)),
               clock: fn -> ~U[2030-09-12 13:00:00.000000Z] end
             )

    assert {:ok, %{first_attempted_at: ^first}} =
             TrainingAnnouncements.get(ctx.actor, announcement.id)

    assert [_, _] = deliveries()
  end

  defp configure_channel do
    previous = Application.get_env(:dhc, :discord_sparring_channel_id)
    Application.put_env(:dhc, :discord_sparring_channel_id, "123456789012345678")
    on_exit(fn -> Application.put_env(:dhc, :discord_sparring_channel_id, previous) end)
  end

  defp perform_due(args, opts \\ []) do
    job = %Oban.Job{
      args: Map.new(args, fn {key, value} -> {Atom.to_string(key), value} end),
      attempt: Keyword.get(opts, :attempt, 1),
      max_attempts: 4
    }

    AnnouncementWorker.perform(job,
      clock: Keyword.get(opts, :clock, fn -> ~U[2030-09-05 13:00:00.000000Z] end)
    )
  end

  defp create_due(ctx, extra \\ %{}) do
    attrs =
      Map.merge(
        %{
          kind: "sparring",
          weekday: Date.day_of_week(ctx.today),
          post_time: ~T[00:00:00],
          title: "Training",
          message: "Come train",
          mention_everyone: false
        },
        extra
      )

    {:ok, %{announcement: announcement}} =
      TrainingAnnouncements.create(ctx.actor, attrs,
        now: DateTime.add(ClubCalendar.to_utc(ctx.today, ~T[00:00:00]), -1, :second)
      )

    announcement
  end

  defp args(announcement, date),
    do: %{announcement_id: announcement.id, occurrence_date: Date.to_iso8601(date)}

  defp deliveries, do: Repo.all(DiscordAnnouncementDelivery)
end
