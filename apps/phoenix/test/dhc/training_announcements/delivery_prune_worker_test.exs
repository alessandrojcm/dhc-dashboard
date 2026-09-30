defmodule Dhc.TrainingAnnouncements.DeliveryPruneWorkerTest do
  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  alias Dhc.Auth.UserRole
  alias Dhc.ClubCalendar
  alias Dhc.ClubCalendar.Holiday
  alias Dhc.Discord.Adapter.Test, as: DiscordAdapter
  alias Dhc.Repo
  alias Dhc.TrainingAnnouncements
  alias Dhc.TrainingAnnouncements.Announcement
  alias Dhc.TrainingAnnouncements.DiscordAnnouncementDelivery
  alias Dhc.TrainingAnnouncements.Workers.AnnouncementWorker
  alias Dhc.TrainingAnnouncements.Workers.DeliveryPruneWorker

  test "prunes both subjects strictly before the Dublin retention horizon and is idempotent" do
    today = ClubCalendar.today()
    horizon = Date.add(today, -400)
    announcement = announcement()

    for date <- [Date.add(horizon, -1), horizon, Date.add(horizon, 1)] do
      occurrence(announcement, date)

      for phase <- ~w(day_before same_day) do
        Repo.insert!(%DiscordAnnouncementDelivery{
          subject: "holiday",
          holiday_date: date,
          phase: phase,
          state: "skipped",
          reason: "holiday"
        })
      end
    end

    assert TrainingAnnouncements.retention_horizon() == horizon
    assert :ok = perform_job(DeliveryPruneWorker, %{})
    remaining = Repo.all(DiscordAnnouncementDelivery)

    assert Enum.sort(Enum.map(remaining, &(&1.occurrence_date || &1.holiday_date))) ==
             [
               horizon,
               horizon,
               horizon,
               Date.add(horizon, 1),
               Date.add(horizon, 1),
               Date.add(horizon, 1)
             ]

    assert :ok = perform_job(DeliveryPruneWorker, %{})

    assert MapSet.new(Repo.all(DiscordAnnouncementDelivery), & &1.id) ==
             MapSet.new(remaining, & &1.id)
  end

  test "retired announcements retain old evidence and remain retrievable" do
    actor = committee_actor()
    announcement = announcement()
    delivery = occurrence(announcement, Date.add(ClubCalendar.today(), -401))
    assert {:ok, _} = TrainingAnnouncements.retire(actor, announcement.id)

    assert :ok = perform_job(DeliveryPruneWorker, %{})
    assert Repo.get!(DiscordAnnouncementDelivery, delivery.id) == delivery
    assert {:ok, %{retired: true}} = TrainingAnnouncements.get(actor, announcement.id)
  end

  test "pruning the only attempted delivery does not make its announcement deletable" do
    start_supervised!({DiscordAdapter, owner: self()})
    previous = Application.get_env(:dhc, :discord_sparring_channel_id)
    Application.put_env(:dhc, :discord_sparring_channel_id, "123456789012345678")
    on_exit(fn -> Application.put_env(:dhc, :discord_sparring_channel_id, previous) end)
    actor = committee_actor()
    date = Date.add(ClubCalendar.today(), -401)
    due_at = %{ClubCalendar.to_utc(date, ~T[14:00:00]) | microsecond: {0, 6}}

    Repo.insert!(%Holiday{
      date: Date.new!(date.year, 1, 1),
      name: "New Year",
      source_id: "new-year",
      fetched_at: DateTime.utc_now()
    })

    assert {:ok, %{announcement: announcement}} =
             TrainingAnnouncements.create(
               actor,
               %{
                 kind: "sparring",
                 one_off_date: date,
                 post_time: ~T[14:00:00],
                 title: "Training",
                 message: "Come train"
               },
               now: DateTime.add(due_at, -1, :second)
             )

    DiscordAdapter.script(:create_message, [{:ok, %{message_id: "234567890123456789"}}])

    DiscordAdapter.script(:create_thread_from_message, [{:ok, %{thread_id: "345678901234567890"}}])

    assert :ok =
             AnnouncementWorker.perform(
               %Oban.Job{
                 args: %{
                   "announcement_id" => announcement.id,
                   "occurrence_date" => Date.to_iso8601(date)
                 },
                 attempt: 1,
                 max_attempts: 4
               },
               clock: fn -> due_at end
             )

    assert [%{state: "delivered", frozen_at: frozen_at}] = Repo.all(DiscordAnnouncementDelivery)
    assert frozen_at != nil
    assert {:ok, %{first_attempted_at: first}} = TrainingAnnouncements.get(actor, announcement.id)
    assert first != nil

    assert :ok = perform_job(DeliveryPruneWorker, %{})
    assert Repo.all(DiscordAnnouncementDelivery) == []
    assert {:error, :attempted} = TrainingAnnouncements.delete(actor, announcement.id)

    assert {:ok, %{first_attempted_at: ^first}} =
             TrainingAnnouncements.get(actor, announcement.id)
  end

  defp committee_actor do
    member = Dhc.MemberFixtures.member_fixture()
    Repo.insert!(%UserRole{principal_id: member.principal_id, role: "coach"})
    member.principal_id
  end

  defp announcement do
    Repo.insert!(%Announcement{
      kind: "sparring",
      weekday: 4,
      post_time: ~T[14:00:00],
      title: "Training",
      message: "Come train"
    })
  end

  defp occurrence(announcement, date) do
    Repo.insert!(%DiscordAnnouncementDelivery{
      subject: "occurrence",
      announcement_id: announcement.id,
      occurrence_date: date,
      state: "skipped",
      reason: "disabled"
    })
  end
end
