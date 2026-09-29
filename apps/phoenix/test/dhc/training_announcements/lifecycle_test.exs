defmodule Dhc.TrainingAnnouncements.LifecycleTest do
  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  alias Dhc.ClubCalendar.Holiday
  alias Dhc.Repo
  alias Dhc.TrainingAnnouncements
  alias Dhc.TrainingAnnouncements.Announcement
  alias Dhc.TrainingAnnouncements.AnnouncementSuppression
  alias Dhc.TrainingAnnouncements.Workers.AnnouncementWorker
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Auth.UserRole

  setup do
    member = Dhc.MemberFixtures.member_fixture()
    Repo.insert!(%UserRole{principal_id: member.principal_id, role: "coach"})

    # A fetched year makes schedule warnings deterministic and network-free.
    Repo.insert!(%Holiday{
      date: ~D[2030-01-01],
      name: "New Year",
      source_id: "new-year",
      fetched_at: DateTime.utc_now()
    })

    %{actor: member.principal_id, now: ~U[2030-09-05 09:00:00Z]}
  end

  test "creating an announcement schedules its first Dublin send instant", %{
    actor: actor,
    now: now
  } do
    assert {:ok, %{announcement: announcement, warnings: []}} =
             TrainingAnnouncements.create(actor, attrs(), now: now)

    assert announcement.kind == "sparring"
    assert [%{args: args, scheduled_at: scheduled_at}] = all_enqueued(worker: AnnouncementWorker)
    assert args == %{"announcement_id" => announcement.id, "occurrence_date" => "2030-09-05"}
    assert DateTime.compare(scheduled_at, ~U[2030-09-05 13:00:00Z]) == :eq
  end

  test "elapsed weekly and one-off slots are rejected without a row or job", %{actor: actor} do
    for extra <- [%{}, %{weekday: nil, one_off_date: ~D[2030-09-05]}] do
      assert {:error, changeset} =
               TrainingAnnouncements.create(actor, attrs(extra), now: ~U[2030-09-05 13:00:00Z])

      assert %{post_time: [_]} = errors_on(changeset)
    end

    assert all_enqueued(worker: AnnouncementWorker) == []
    assert {:ok, []} = TrainingAnnouncements.list(actor)
  end

  test "a schedule edit swaps the sole pending job; an elapsed edit leaves it unchanged", %{
    actor: actor,
    now: now
  } do
    {:ok, %{announcement: announcement}} = TrainingAnnouncements.create(actor, attrs(), now: now)

    assert {:ok, %{announcement: edited, warnings: []}} =
             TrainingAnnouncements.update_schedule(
               actor,
               announcement.id,
               %{post_time: ~T[16:00:00]},
               now: now
             )

    assert edited.post_time == ~T[16:00:00]
    assert [job] = all_enqueued(worker: AnnouncementWorker)
    assert DateTime.compare(job.scheduled_at, ~U[2030-09-05 15:00:00Z]) == :eq
    assert job.args["occurrence_date"] == "2030-09-05"

    assert {:error, _} =
             TrainingAnnouncements.update_schedule(
               actor,
               announcement.id,
               %{post_time: ~T[08:00:00]},
               now: now
             )

    assert [^job] = all_enqueued(worker: AnnouncementWorker)
  end

  test "collision and dormant-exception warnings are non-blocking", %{actor: actor, now: now} do
    {:ok, %{announcement: first}} = TrainingAnnouncements.create(actor, attrs(), now: now)

    assert {:ok, %{warnings: [:slot_collision]}} =
             TrainingAnnouncements.create(actor, attrs(), now: now)

    Repo.insert!(%AnnouncementSuppression{
      announcement_id: first.id,
      from_date: ~D[2030-09-05],
      to_date: ~D[2030-09-05]
    })

    assert {:ok, %{warnings: [:exception_intersection_changed]}} =
             TrainingAnnouncements.update_schedule(actor, first.id, %{weekday: 5}, now: now)
  end

  test "disable, enable and copy edits leave jobs alone; retirement is terminal", %{
    actor: actor,
    now: now
  } do
    {:ok, %{announcement: announcement}} = TrainingAnnouncements.create(actor, attrs(), now: now)
    [job] = all_enqueued(worker: AnnouncementWorker)
    assert {:ok, %{enabled: false}} = TrainingAnnouncements.disable(actor, announcement.id)
    assert {:ok, %{enabled: true}} = TrainingAnnouncements.enable(actor, announcement.id)

    assert {:ok, %{title: "New title", weekday: 4}} =
             TrainingAnnouncements.update_copy(
               actor,
               announcement.id,
               %{title: "New title", weekday: 5}
             )

    assert [^job] = all_enqueued(worker: AnnouncementWorker)
    assert {:ok, %{retired: true}} = TrainingAnnouncements.retire(actor, announcement.id)
    assert all_enqueued(worker: AnnouncementWorker) == []
    assert {:ok, []} = TrainingAnnouncements.list(actor)
    assert {:ok, [%{id: id}]} = TrainingAnnouncements.list(actor, include_retired: true)
    assert id == announcement.id
    assert {:ok, %{retired: true}} = TrainingAnnouncements.get(actor, announcement.id)
    assert {:error, :retired} = TrainingAnnouncements.enable(actor, announcement.id)
  end

  test "attempted announcements stay undeletable even after evidence is pruned", %{
    actor: actor,
    now: now
  } do
    {:ok, %{announcement: announcement}} = TrainingAnnouncements.create(actor, attrs(), now: now)
    # Simulate the Delivery ticket's durable first-freeze stamp, not a public edit.
    Repo.update_all(from(a in Announcement, where: a.id == ^announcement.id),
      set: [first_attempted_at: DateTime.utc_now()]
    )

    assert {:error, :attempted} = TrainingAnnouncements.delete(actor, announcement.id)
    assert [_] = all_enqueued(worker: AnnouncementWorker)

    {:ok, %{announcement: one_off}} =
      TrainingAnnouncements.create(
        actor,
        attrs(%{weekday: nil, one_off_date: ~D[2030-09-06]}),
        now: now
      )

    Repo.update_all(from(a in Announcement, where: a.id == ^one_off.id),
      set: [first_attempted_at: DateTime.utc_now()]
    )

    assert {:error, :delivery_started} =
             TrainingAnnouncements.update_schedule(
               actor,
               one_off.id,
               %{one_off_date: ~D[2030-09-07]},
               now: now
             )
  end

  test "deleting an unattempted announcement removes its pending job", %{actor: actor, now: now} do
    {:ok, %{announcement: announcement}} = TrainingAnnouncements.create(actor, attrs(), now: now)
    assert {:ok, _} = TrainingAnnouncements.delete(actor, announcement.id)
    assert {:error, :not_found} = TrainingAnnouncements.get(actor, announcement.id)
    assert all_enqueued(worker: AnnouncementWorker) == []
  end

  test "only an active committee principal can read, write or preview", %{actor: actor, now: now} do
    member = Dhc.MemberFixtures.member_fixture()

    assert {:error, :forbidden} =
             TrainingAnnouncements.create(member.principal_id, attrs(), now: now)

    assert {:error, :forbidden} = TrainingAnnouncements.list(member.principal_id)

    assert {:error, :forbidden} =
             TrainingAnnouncements.get(member.principal_id, Ecto.UUID.generate())

    assert {:error, :forbidden} =
             TrainingAnnouncements.preview_copy(
               member.principal_id,
               %{kind: "sparring", title: "Title", message: "Message", date: ~D[2030-09-05]}
             )

    Repo.delete_all(from(r in UserRole, where: r.principal_id == ^actor))
    assert {:error, :forbidden} = TrainingAnnouncements.create(actor, attrs(), now: now)
  end

  test "preview and saves validate rendered length and explicit mention copy", %{
    actor: actor,
    now: now
  } do
    assert {:ok, %{thread_name: "Thursday", rendered_message: "@everyone\nWho is coming?"}} =
             TrainingAnnouncements.preview_copy(actor, %{
               kind: "sparring",
               title: "{{weekday}}",
               message: "Who is coming?",
               mention_everyone: true,
               date: ~D[2030-09-05]
             })

    assert {:error, _} =
             TrainingAnnouncements.create(
               actor,
               attrs(%{message: String.duplicate("x", 1995), mention_everyone: true}),
               now: now
             )

    assert {:error, _} =
             TrainingAnnouncements.preview_copy(
               actor,
               %{kind: "sparring", title: "Title", message: "{{unknown}}", date: ~D[2030-09-05]}
             )
  end

  test "an available old job is replaced rather than keeping its old instant", %{
    actor: actor,
    now: now
  } do
    {:ok, %{announcement: announcement}} = TrainingAnnouncements.create(actor, attrs(), now: now)

    Repo.update_all(from(j in Oban.Job, where: j.args["announcement_id"] == ^announcement.id),
      set: [state: "available"]
    )

    assert {:ok, _} =
             TrainingAnnouncements.update_schedule(actor, announcement.id, %{weekday: 5},
               now: now
             )

    assert [job] = all_enqueued(worker: AnnouncementWorker)
    assert job.args["occurrence_date"] == "2030-09-06"
    assert DateTime.compare(job.scheduled_at, ~U[2030-09-06 13:00:00Z]) == :eq
  end

  test "an inactive committee principal cannot read, edit or preview", %{actor: actor, now: now} do
    {:ok, %{announcement: announcement}} = TrainingAnnouncements.create(actor, attrs(), now: now)

    Repo.update_all(from(p in UserProfile, where: p.principal_id == ^actor),
      set: [is_active: false]
    )

    assert {:error, :forbidden} = TrainingAnnouncements.get(actor, announcement.id)
    assert {:error, :forbidden} = TrainingAnnouncements.list(actor)
    assert {:error, :forbidden} = TrainingAnnouncements.disable(actor, announcement.id)

    assert {:error, :forbidden} =
             TrainingAnnouncements.preview_copy(
               actor,
               %{kind: "sparring", title: "Title", message: "Message", date: ~D[2030-09-05]}
             )
  end

  test "executing drivers complete rather than snoozing or overwriting the edited schedule", %{
    actor: actor,
    now: now
  } do
    {:ok, %{announcement: announcement}} = TrainingAnnouncements.create(actor, attrs(), now: now)
    [old_job] = all_enqueued(worker: AnnouncementWorker)
    Repo.update_all(from(j in Oban.Job, where: j.id == ^old_job.id), set: [state: "executing"])

    assert {:ok, _} =
             TrainingAnnouncements.update_schedule(
               actor,
               announcement.id,
               %{post_time: ~T[16:00:00]},
               now: now
             )

    assert :ok = AnnouncementWorker.perform(old_job, clock: fn -> now end)
    assert [replacement] = all_enqueued(worker: AnnouncementWorker)
    assert DateTime.compare(replacement.scheduled_at, ~U[2030-09-05 15:00:00Z]) == :eq

    assert {:ok, _} =
             TrainingAnnouncements.update_schedule(actor, announcement.id, %{weekday: 5},
               now: now
             )

    [new_job] = all_enqueued(worker: AnnouncementWorker)
    assert :ok = AnnouncementWorker.perform(old_job, clock: fn -> now end)
    assert [^new_job] = all_enqueued(worker: AnnouncementWorker)
    assert {:ok, _} = TrainingAnnouncements.retire(actor, announcement.id)
    assert :ok = AnnouncementWorker.perform(old_job, clock: fn -> now end)
    assert all_enqueued(worker: AnnouncementWorker) == []
  end

  defp attrs(extra \\ %{}) do
    Map.merge(
      %{
        kind: "sparring",
        weekday: 4,
        post_time: ~T[14:00:00],
        title: "Sparring {{date}}",
        message: "Who is coming?",
        mention_everyone: false
      },
      extra
    )
  end
end
