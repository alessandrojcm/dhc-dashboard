defmodule Dhc.TrainingAnnouncements.AnnouncementWorkerTest do
  @moduledoc """
  Job arguments → `Execution.evaluate/3` wiring only. Resolution, copy and
  channel scenarios live in `ExecutionTest`; Discord progression in
  `DeliveryTest`.
  """
  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  alias Dhc.Auth.UserRole
  alias Dhc.ClubCalendar.Holiday
  alias Dhc.Discord.Adapter.Test, as: DiscordAdapter
  alias Dhc.Repo
  alias Dhc.TrainingAnnouncements
  alias Dhc.TrainingAnnouncements.DiscordAnnouncementDelivery, as: Evidence
  alias Dhc.TrainingAnnouncements.Execution
  alias Dhc.TrainingAnnouncements.Workers.AnnouncementWorker

  @clock_at ~U[2030-09-05 13:00:00.000000Z]

  setup do
    start_supervised!({DiscordAdapter, owner: self()})
    member = Dhc.MemberFixtures.member_fixture()
    Repo.insert!(%UserRole{principal_id: member.principal_id, role: "coach"})

    Repo.insert!(%Holiday{
      date: ~D[2030-01-01],
      name: "New Year",
      source_id: "new-year",
      fetched_at: DateTime.utc_now()
    })

    previous = Application.get_env(:dhc, :discord_sparring_channel_id)
    Application.put_env(:dhc, :discord_sparring_channel_id, "123456789012345678")
    on_exit(fn -> Application.put_env(:dhc, :discord_sparring_channel_id, previous) end)

    {:ok, %{announcement: announcement}} =
      TrainingAnnouncements.create(
        member.principal_id,
        %{
          kind: "sparring",
          weekday: 4,
          post_time: ~T[14:00:00],
          title: "Training",
          message: "Come train",
          mention_everyone: false
        },
        now: ~U[2030-09-04 12:00:00Z]
      )

    %{announcement: announcement}
  end

  test "the enqueued args evaluate that announcement's occurrence", %{announcement: announcement} do
    assert [job] = all_enqueued(worker: AnnouncementWorker)
    assert job.args == %{"announcement_id" => announcement.id, "occurrence_date" => "2030-09-05"}

    DiscordAdapter.script(:create_message, [{:ok, %{message_id: "234567890123456789"}}])

    DiscordAdapter.script(:create_thread_from_message, [{:ok, %{thread_id: "345678901234567890"}}])

    assert :ok = perform(job)
    assert [%{announcement_id: id, occurrence_date: ~D[2030-09-05]}] = Repo.all(Evidence)
    assert id == announcement.id
  end

  test "an unknown announcement completes without evidence" do
    assert :ok = perform(job(Ecto.UUID.generate(), "2030-09-05"))
    assert Repo.all(Evidence) == []
  end

  test "malformed arguments are discarded", %{announcement: announcement} do
    for args <- [
          %{"announcement_id" => "not-a-uuid", "occurrence_date" => "2030-09-05"},
          %{"announcement_id" => announcement.id, "occurrence_date" => "05/09/2030"},
          %{"announcement_id" => announcement.id}
        ] do
      assert {:discard, :invalid_args} =
               AnnouncementWorker.perform(%Oban.Job{args: args},
                 clock: Execution.clock(@clock_at)
               )
    end

    assert Repo.all(Evidence) == []
  end

  defp job(id, date) do
    %Oban.Job{
      args: %{"announcement_id" => id, "occurrence_date" => date},
      attempt: 1,
      max_attempts: 4
    }
  end

  defp perform(job),
    do:
      AnnouncementWorker.perform(%{job | attempt: max(job.attempt, 1)},
        clock: Execution.clock(@clock_at)
      )
end
