defmodule Dhc.TrainingAnnouncements.HolidayAnnouncementWorkerTest do
  @moduledoc """
  Job arguments → `Execution.evaluate/3` wiring only; Holiday Announcement
  behaviour lives in `HolidayAnnouncementsTest` and `ExecutionTest`.
  """
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

    {:ok, _} =
      TrainingAnnouncements.create(
        member.principal_id,
        %{
          kind: "roll_call",
          weekday: 1,
          post_time: ~T[14:00:00],
          title: "Roll call",
          message: "Come train",
          mention_everyone: false
        },
        now: ~U[2030-08-01 12:00:00Z]
      )

    :ok
  end

  test "a day-before job evaluates that phase and returns its snooze" do
    assert [job] = all_enqueued(worker: HolidayAnnouncementWorker)
    assert job.args == %{"holiday_date" => "2030-08-05", "phase" => "day_before"}

    assert {:snooze, 3600} = perform(job, ~U[2030-08-04 12:00:00.000000Z])
    assert Repo.all(Evidence) == []
  end

  test "a same-day recovery job evaluates the same-day reference" do
    DiscordAdapter.script(:create_message, [
      {:error, %ApiError{status: 429, message: "slow"}},
      {:ok, %{message_id: "234567890123456789"}}
    ])

    ref = {:holiday, "same_day", ~D[2030-08-05]}

    assert {:error, {:rate_limited, _}} =
             Execution.evaluate(ref, Execution.clock(~U[2030-08-05 13:00:00.000000Z]))

    assert [recovery] =
             Enum.filter(
               all_enqueued(worker: HolidayAnnouncementWorker),
               &(&1.args["phase"] == "same_day")
             )

    assert :ok = perform(recovery, ~U[2030-08-05 13:01:00.000000Z])
    assert [%{phase: "same_day", state: "delivered"}] = Repo.all(Evidence)
  end

  test "malformed arguments are discarded" do
    for args <- [
          %{"holiday_date" => "2030-08-05", "phase" => "week_before"},
          %{"holiday_date" => "05/08/2030", "phase" => "same_day"},
          %{"phase" => "same_day"}
        ] do
      assert {:discard, :invalid_args} = perform(%Oban.Job{args: args}, ~U[2030-08-05 13:00:00Z])
    end
  end

  defp perform(job, now),
    do:
      HolidayAnnouncementWorker.perform(%{job | attempt: 1, max_attempts: 4},
        clock: Execution.clock(now)
      )
end
