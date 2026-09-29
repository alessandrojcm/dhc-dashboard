defmodule Dhc.TrainingAnnouncements.AnnouncementWorkerTest do
  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  alias Dhc.Auth.UserRole
  alias Dhc.ClubCalendar
  alias Dhc.ClubCalendar.Holiday
  alias Dhc.Repo
  alias Dhc.TrainingAnnouncements
  alias Dhc.TrainingAnnouncements.Announcement
  alias Dhc.TrainingAnnouncements.DiscordAnnouncementDelivery
  alias Dhc.TrainingAnnouncements.Workers.AnnouncementWorker

  setup do
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

  test "invalid resolved copy blocks; configured valid copy neither posts nor manufactures evidence",
       ctx do
    Sentry.Test.setup_sentry()
    previous = Application.get_env(:dhc, :discord_sparring_channel_id)
    Application.put_env(:dhc, :discord_sparring_channel_id, "123456789012345678")
    on_exit(fn -> Application.put_env(:dhc, :discord_sparring_channel_id, previous) end)
    announcement = create_due(ctx)
    assert :ok = perform_due(args(announcement, ctx.today))
    assert deliveries() == []

    assert {:ok, %{first_attempted_at: nil}} =
             TrainingAnnouncements.get(ctx.actor, announcement.id)

    # Persist corrupt legacy copy to exercise the worker's validation fence.
    Repo.update_all(from(a in Announcement, where: a.id == ^announcement.id),
      set: [message: "{{unsupported}}"]
    )

    assert :ok = perform_due(args(announcement, ctx.today))
    assert [%{state: "blocked", reason: "invalid_copy", frozen_at: nil}] = deliveries()
    assert [%Sentry.Event{extra: %{reason: "invalid_copy"}}] = Sentry.Test.pop_sentry_reports()
  end

  defp perform_due(args) do
    job = %Oban.Job{args: Map.new(args, fn {key, value} -> {Atom.to_string(key), value} end)}
    AnnouncementWorker.perform(job, clock: fn -> ~U[2030-09-05 13:00:00.000000Z] end)
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
