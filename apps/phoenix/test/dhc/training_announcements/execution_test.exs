defmodule Dhc.TrainingAnnouncements.ExecutionTest do
  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  alias Dhc.Auth.UserRole
  alias Dhc.ClubCalendar
  alias Dhc.ClubCalendar.Holiday
  alias Dhc.Discord.Adapter.Test, as: DiscordAdapter
  alias Dhc.Repo
  alias Dhc.TrainingAnnouncements
  alias Dhc.TrainingAnnouncements.Announcement
  alias Dhc.TrainingAnnouncements.DiscordAnnouncementDelivery, as: Evidence
  alias Dhc.TrainingAnnouncements.Execution
  alias Dhc.TrainingAnnouncements.Workers.AnnouncementWorker
  alias Dhc.TrainingAnnouncements.Workers.HolidayAnnouncementWorker

  # Thursday 2030-09-05, 14:00 Dublin (IST): the 14:00 slot is due.
  @today ~D[2030-09-05]
  @due ~U[2030-09-05 13:00:00.000000Z]
  @channel "123456789012345678"

  setup do
    start_supervised!({DiscordAdapter, owner: self()})
    member = Dhc.MemberFixtures.member_fixture()
    Repo.insert!(%UserRole{principal_id: member.principal_id, role: "coach"})
    holiday(~D[2030-01-01], "New Year")

    keys = [
      :discord_sparring_channel_id,
      :discord_roll_call_channel_id,
      :discord_training_announcements_channel_id
    ]

    previous = Map.new(keys, &{&1, Application.fetch_env(:dhc, &1)})
    Enum.each(keys, &Application.put_env(:dhc, &1, @channel))

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:dhc, key, value)
        {key, :error} -> Application.delete_env(:dhc, key)
      end)
    end)

    %{actor: member.principal_id}
  end

  describe "an Announcement Occurrence" do
    test "posts frozen copy, stamps the first attempt and schedules the next week", ctx do
      announcement = create(ctx, %{mention_everyone: true})
      script_post()

      assert :ok = evaluate(announcement, @today)

      assert [evidence] = Repo.all(Evidence)
      assert evidence.state == "delivered"
      assert evidence.resolved_outcome == "post"
      assert evidence.precedence_chain == ["disablement", "suppression", "override", "defaults"]
      assert evidence.rendered_message == "@everyone\nCome train"
      assert evidence.thread_name == "Training Thursday"
      assert evidence.channel_id == @channel
      assert evidence.frozen_at == @due

      assert_receive {:create_message, [@channel, %{allowed_mentions: %{parse: ["everyone"]}}]}
      assert_receive {:create_thread_from_message, [@channel, "234567890123456789", _]}

      assert %{first_attempted_at: @due} = Repo.get!(Announcement, announcement.id)
      assert [next] = all_enqueued(worker: AnnouncementWorker)
      assert next.args["occurrence_date"] == "2030-09-12"
    end

    test "a bank holiday skips a roll call and drives the same-day Holiday Announcement", ctx do
      holiday(@today, "Thursday Holiday")
      announcement = create(ctx, %{kind: "roll_call"})
      DiscordAdapter.script(:create_message, [{:ok, %{message_id: "234567890123456789"}}])

      assert :ok = evaluate(announcement, @today)

      assert [%{state: "skipped", reason: "holiday", precedence_chain: ["holiday"]}] =
               occurrence_rows()

      assert [%{phase: "same_day", state: "delivered", holiday_date: @today}] = holiday_rows()
      assert_receive {:create_message, [@channel, %{content: content}]}
      assert content =~ "Today is Thursday Holiday"
      refute_receive {:create_thread_from_message, _}
    end

    test "disablement skips without freezing or stamping the first attempt", ctx do
      announcement = create(ctx)
      {:ok, _} = TrainingAnnouncements.disable(ctx.actor, announcement.id)

      assert :ok = evaluate(announcement, @today)

      assert [%{state: "skipped", reason: "disabled", frozen_at: nil, concluded_at: @due}] =
               Repo.all(Evidence)

      assert %{first_attempted_at: nil} = Repo.get!(Announcement, announcement.id)
      refute_receive {:create_message, _}
    end

    test "a suppression skips and records the applied suppression", ctx do
      announcement = create(ctx)

      {:ok, suppression} =
        TrainingAnnouncements.suppress(
          ctx.actor,
          announcement.id,
          %{from_date: @today, to_date: @today},
          now: ~U[2030-09-01 12:00:00Z]
        )

      assert :ok = evaluate(announcement, @today)

      assert [%{state: "skipped", reason: "suppressed", applied_suppression_id: id}] =
               Repo.all(Evidence)

      assert id == suppression.id
      refute_receive {:create_message, _}
    end

    test "past its Dublin date it is missed, never posted", ctx do
      announcement = create(ctx)

      assert :ok = evaluate(announcement, @today, ~U[2030-09-05 23:30:00.000000Z])

      assert [
               %{
                 state: "missed",
                 reason: "late",
                 resolved_outcome: "missed",
                 precedence_chain: []
               }
             ] = Repo.all(Evidence)

      refute_receive {:create_message, _}
    end

    test "an Override's copy is what freezes", ctx do
      announcement = create(ctx)

      {:ok, override} =
        TrainingAnnouncements.override(
          ctx.actor,
          announcement.id,
          %{from_date: @today, to_date: @today, title: "Special", message: "Special copy"},
          now: ~U[2030-09-01 12:00:00Z]
        )

      script_post()
      assert :ok = evaluate(announcement, @today)

      assert [evidence] = Repo.all(Evidence)
      assert evidence.resolved_outcome == "post_override"
      assert evidence.applied_override_id == override.id
      assert evidence.title_source == "Special"
      assert evidence.rendered_message == "Special copy"
      assert_receive {:create_message, [_, %{content: "Special copy"}]}
    end

    test "invalid copy blocks before freezing", ctx do
      announcement = create(ctx)

      Repo.update_all(from(a in Announcement, where: a.id == ^announcement.id),
        set: [message: "{{unsupported}}"]
      )

      assert :ok = evaluate(announcement, @today)

      assert [%{state: "blocked", reason: "invalid_copy", frozen_at: nil, channel_id: nil}] =
               Repo.all(Evidence)

      refute_receive {:create_message, _}
    end

    test "an unconfigured channel blocks before freezing", ctx do
      Application.delete_env(:dhc, :discord_sparring_channel_id)
      announcement = create(ctx)

      assert :ok = evaluate(announcement, @today)

      assert [%{state: "blocked", reason: "unconfigured_channel", rendered_message: nil}] =
               Repo.all(Evidence)

      assert %{first_attempted_at: nil} = Repo.get!(Announcement, announcement.id)
    end

    test "a replay progresses the existing row and never writes a second one", ctx do
      announcement = create(ctx)
      {:ok, _} = TrainingAnnouncements.disable(ctx.actor, announcement.id)
      assert :ok = evaluate(announcement, @today)
      [first] = Repo.all(Evidence)

      # Re-enabling must not reinterpret an occurrence already evaluated.
      {:ok, _} = TrainingAnnouncements.enable(ctx.actor, announcement.id)
      assert :ok = evaluate(announcement, @today, ~U[2030-09-05 13:30:00.000000Z])

      assert [^first] = Repo.all(Evidence)
      refute_receive {:create_message, _}
    end

    test "an early driver writes nothing and keeps one pending driver", ctx do
      announcement = create(ctx)

      assert :ok = evaluate(announcement, @today, ~U[2030-09-05 12:00:00.000000Z])

      assert Repo.all(Evidence) == []
      assert [job] = all_enqueued(worker: AnnouncementWorker)
      assert job.args["occurrence_date"] == "2030-09-05"
    end
  end

  describe "a Holiday Announcement" do
    setup ctx do
      holiday(~D[2030-09-12], "Next Thursday Holiday")
      %{roll_call: create(ctx, %{kind: "roll_call"})}
    end

    test "day-before freezes fixed copy on the preceding day without a recovery driver" do
      DiscordAdapter.script(:create_message, [{:ok, %{message_id: "234567890123456789"}}])

      assert :ok =
               Execution.evaluate(
                 {:holiday, "day_before", ~D[2030-09-12]},
                 Execution.clock(~U[2030-09-11 13:00:00.000000Z])
               )

      assert [
               %{
                 phase: "day_before",
                 state: "delivered",
                 post_time: ~T[14:00:00],
                 mention_everyone: true,
                 precedence_chain: ["holiday"]
               }
             ] = holiday_rows()

      assert_receive {:create_message, [@channel, %{content: content}]}
      assert content =~ "Tomorrow is Next Thursday Holiday"

      refute Enum.any?(
               all_enqueued(worker: HolidayAnnouncementWorker),
               &(&1.args["phase"] == "same_day")
             )
    end

    test "day-before before its slot snoozes without evidence" do
      assert {:snooze, 3600} =
               Execution.evaluate(
                 {:holiday, "day_before", ~D[2030-09-12]},
                 Execution.clock(~U[2030-09-11 12:00:00.000000Z])
               )

      assert holiday_rows() == []
    end

    test "same-day commits a recovery driver with its frozen row" do
      DiscordAdapter.script(:create_message, [
        {:error, %Dhc.Discord.ApiError{status: 429, message: "Rate limited"}}
      ])

      assert {:error, {:rate_limited, _}} =
               Execution.evaluate(
                 {:holiday, "same_day", ~D[2030-09-12]},
                 Execution.clock(~U[2030-09-12 13:00:00.000000Z])
               )

      assert [%{phase: "same_day", state: "frozen"}] = holiday_rows()

      assert [%{args: %{"phase" => "same_day", "holiday_date" => "2030-09-12"}}] =
               Enum.filter(
                 all_enqueued(worker: HolidayAnnouncementWorker),
                 &(&1.args["phase"] == "same_day")
               )
    end

    test "an overdue day-before is missed and a replay keeps the one row" do
      clock = Execution.clock(~U[2030-09-12 13:00:00.000000Z])
      assert :ok = Execution.evaluate({:holiday, "day_before", ~D[2030-09-12]}, clock)
      assert :ok = Execution.evaluate({:holiday, "day_before", ~D[2030-09-12]}, clock)

      assert [%{phase: "day_before", state: "missed", reason: "late", frozen_at: nil}] =
               holiday_rows()

      refute_receive {:create_message, _}
    end

    test "with every roll call disabled there is nothing to announce", ctx do
      {:ok, _} = TrainingAnnouncements.disable(ctx.actor, ctx.roll_call.id)

      assert :ok =
               Execution.evaluate(
                 {:holiday, "same_day", ~D[2030-09-12]},
                 Execution.clock(~U[2030-09-12 13:00:00.000000Z])
               )

      assert holiday_rows() == []
    end
  end

  describe "time is read inside the claim, not when the clock was built" do
    test "a claim held past Dublin midnight records the occurrence missed", ctx do
      announcement = create(ctx)
      clock = advancing(@due, ~U[2030-09-05 23:00:01.000000Z])

      assert :ok = Execution.evaluate({:announcement, announcement.id, @today}, clock)

      # Missed by Execution itself (never frozen), not by Delivery afterwards.
      assert [
               %{
                 state: "missed",
                 frozen_at: nil,
                 resolved_outcome: "missed",
                 concluded_at: ~U[2030-09-05 23:00:01.000000Z]
               }
             ] = Repo.all(Evidence)

      refute_receive {:create_message, _}
    end

    test "a claim held past the slot freezes and stamps the claim instant", ctx do
      announcement = create(ctx)
      claimed = ~U[2030-09-05 13:05:00.000000Z]
      script_post()

      assert :ok =
               Execution.evaluate(
                 {:announcement, announcement.id, @today},
                 advancing(~U[2030-09-05 12:59:00.000000Z], claimed)
               )

      assert [%{state: "delivered", frozen_at: ^claimed}] = Repo.all(Evidence)
      assert %{first_attempted_at: ^claimed} = Repo.get!(Announcement, announcement.id)
    end

    test "a holiday claim held past its slot freezes instead of snoozing", ctx do
      holiday(@today, "Thursday Holiday")
      create(ctx, %{kind: "roll_call"})
      DiscordAdapter.script(:create_message, [{:ok, %{message_id: "234567890123456789"}}])
      claimed = ~U[2030-09-05 13:01:00.000000Z]

      assert :ok =
               Execution.evaluate(
                 {:holiday, "same_day", @today},
                 advancing(~U[2030-09-05 12:59:00.000000Z], claimed)
               )

      assert [%{state: "delivered", frozen_at: ^claimed}] = holiday_rows()
    end
  end

  test "the clock holds Dublin today, civil time and the holiday set" do
    holiday(~D[2030-09-08], "Sunday Holiday")
    clock = Execution.clock(~U[2030-09-05 23:30:00Z])

    assert clock.today == ~D[2030-09-06]
    assert clock.now_time == ~T[00:30:00]
    assert Map.keys(clock.holidays) == [~D[2030-09-08]]
    assert {clock.from, clock.through} == {~D[2030-09-06], ~D[2030-09-14]}
    assert clock.tick.() == ~U[2030-09-05 23:30:00Z]

    assert [%{date: ~D[2030-09-08]}] =
             Execution.holidays_between(clock, ~D[2030-09-06], ~D[2030-09-08])

    assert Execution.holidays_between(clock, ~D[2030-09-09], ~D[2030-09-14]) == []
  end

  defp evaluate(announcement, date, now \\ @due),
    do: Execution.evaluate({:announcement, announcement.id, date}, Execution.clock(now))

  # A clock built at one instant whose readings (the claim's) are another.
  defp advancing(built, claimed), do: %{Execution.clock(built) | tick: fn -> claimed end}

  defp script_post do
    DiscordAdapter.script(:create_message, [{:ok, %{message_id: "234567890123456789"}}])

    DiscordAdapter.script(:create_thread_from_message, [{:ok, %{thread_id: "345678901234567890"}}])
  end

  defp create(ctx, extra \\ %{}) do
    {:ok, %{announcement: announcement}} =
      TrainingAnnouncements.create(
        ctx.actor,
        Map.merge(
          %{
            kind: "sparring",
            weekday: Date.day_of_week(@today),
            post_time: ~T[14:00:00],
            title: "Training {{weekday}}",
            message: "Come train",
            mention_everyone: false
          },
          extra
        ),
        now: ClubCalendar.to_utc(Date.add(@today, -1), ~T[12:00:00])
      )

    announcement
  end

  defp holiday(date, name) do
    Repo.insert!(%Holiday{
      date: date,
      name: name,
      source_id: Date.to_iso8601(date),
      fetched_at: DateTime.utc_now()
    })
  end

  defp occurrence_rows, do: Repo.all(from(d in Evidence, where: d.subject == "occurrence"))
  defp holiday_rows, do: Repo.all(from(d in Evidence, where: d.subject == "holiday"))
end
