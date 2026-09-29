defmodule Dhc.TrainingAnnouncements.ExceptionsTest do
  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  alias Dhc.Auth.UserRole
  alias Dhc.ClubCalendar.Holiday
  alias Dhc.Repo
  alias Dhc.TrainingAnnouncements
  alias Dhc.TrainingAnnouncements.DiscordAnnouncementDelivery
  alias Dhc.TrainingAnnouncements.Occurrences
  alias Dhc.TrainingAnnouncements.Workers.AnnouncementWorker

  setup do
    member = Dhc.MemberFixtures.member_fixture()
    Repo.insert!(%UserRole{principal_id: member.principal_id, role: "coach"})

    Repo.insert!(%Holiday{
      date: ~D[2030-01-01],
      name: "New Year",
      source_id: "ny",
      fetched_at: DateTime.utc_now()
    })

    now = ~U[2030-09-05 09:00:00.000000Z]

    {:ok, %{announcement: announcement}} =
      TrainingAnnouncements.create(
        member.principal_id,
        %{
          kind: "sparring",
          weekday: 4,
          post_time: ~T[14:00:00],
          title: "Training",
          message: "Default",
          mention_everyone: false
        },
        now: now
      )

    %{actor: member.principal_id, announcement: announcement, now: now}
  end

  test "ranges go dormant and apply again; warnings compare intersecting sets", ctx do
    {:ok, suppression} =
      TrainingAnnouncements.suppress(ctx.actor, ctx.announcement.id, range(), now: ctx.now)

    assert {:ok, %{warnings: []}} =
             TrainingAnnouncements.update_schedule(ctx.actor, ctx.announcement.id, %{weekday: 5},
               now: ctx.now
             )

    {:ok, _} =
      TrainingAnnouncements.remove_suppression(ctx.actor, ctx.announcement.id, suppression.id)

    {:ok, single} =
      TrainingAnnouncements.suppress(
        ctx.actor,
        ctx.announcement.id,
        %{from_date: ~D[2030-09-05], to_date: ~D[2030-09-05]},
        now: ctx.now
      )

    for weekday <- [4, 5, 4] do
      assert {:ok, %{warnings: [:exception_intersection_changed]}} =
               TrainingAnnouncements.update_schedule(
                 ctx.actor,
                 ctx.announcement.id,
                 %{weekday: weekday},
                 now: ctx.now
               )
    end

    assert {:ok, [^single]} =
             TrainingAnnouncements.list_suppressions(ctx.actor, ctx.announcement.id)

    assert :ok = run_due(ctx)

    assert %{reason: "suppressed", applied_suppression_id: id} =
             Repo.one!(DiscordAnnouncementDelivery)

    assert id == single.id
  end

  test "overrides replace either or both fields and reject overlapping inclusive ranges", ctx do
    for attrs <- [
          %{title: "Special"},
          %{message: "Special {{weekday}}"},
          %{title: "Special", message: "Both"}
        ] do
      assert {:ok, override} =
               TrainingAnnouncements.override(
                 ctx.actor,
                 ctx.announcement.id,
                 Map.merge(range(), attrs),
                 now: ctx.now
               )

      assert {:ok, [^override]} =
               TrainingAnnouncements.list_overrides(ctx.actor, ctx.announcement.id)

      resolved = Occurrences.resolve_due(ctx.announcement, ~D[2030-09-05], overrides: [override])
      assert resolved.title == Map.get(attrs, :title, "Training")
      assert resolved.message == Map.get(attrs, :message, "Default")
      assert resolved.applied_override_id == override.id

      assert {:ok, _} =
               TrainingAnnouncements.remove_override(ctx.actor, ctx.announcement.id, override.id)
    end

    {:ok, _} =
      TrainingAnnouncements.override(
        ctx.actor,
        ctx.announcement.id,
        Map.merge(range(), %{title: "First"}),
        now: ctx.now
      )

    assert {:error, changeset} =
             TrainingAnnouncements.override(
               ctx.actor,
               ctx.announcement.id,
               %{from_date: ~D[2030-09-12], to_date: ~D[2030-09-19], message: "Second"},
               now: ctx.now
             )

    assert %{from_date: ["overlaps another override for this announcement"]} =
             errors_on(changeset)
  end

  test "past dates, invalid ranges, empty copy and dates with begun deliveries are rejected",
       ctx do
    for operation <- [:suppress, :override] do
      attrs = Map.put(range(), :message, "Special")

      assert {:error, changeset} =
               apply(TrainingAnnouncements, operation, [
                 ctx.actor,
                 ctx.announcement.id,
                 %{attrs | from_date: ~D[2030-09-04]},
                 [now: ctx.now]
               ])

      assert %{from_date: [_]} = errors_on(changeset)

      assert {:error, changeset} =
               apply(TrainingAnnouncements, operation, [
                 ctx.actor,
                 ctx.announcement.id,
                 %{attrs | to_date: ~D[2030-09-04]},
                 [now: ctx.now]
               ])

      assert %{to_date: [_]} = errors_on(changeset)
    end

    assert {:error, _} =
             TrainingAnnouncements.override(ctx.actor, ctx.announcement.id, range(), now: ctx.now)

    assert {:error, _} =
             TrainingAnnouncements.override(
               ctx.actor,
               ctx.announcement.id,
               Map.merge(range(), %{message: "{{unknown}}"}),
               now: ctx.now
             )

    Repo.insert!(%DiscordAnnouncementDelivery{
      subject: "occurrence",
      announcement_id: ctx.announcement.id,
      occurrence_date: ~D[2030-09-12],
      state: "frozen",
      frozen_at: ctx.now
    })

    for operation <- [:suppress, :override] do
      assert {:error, changeset} =
               apply(TrainingAnnouncements, operation, [
                 ctx.actor,
                 ctx.announcement.id,
                 Map.put(range(), :title, "Special"),
                 [now: ctx.now]
               ])

      assert %{from_date: ["delivery has already begun in this range"]} = errors_on(changeset)
    end
  end

  test "exceptions authorize before reads and removals are scoped", ctx do
    outsider = Dhc.MemberFixtures.member_fixture().principal_id

    for operation <- [:suppress, :override] do
      assert {:error, :forbidden} =
               apply(TrainingAnnouncements, operation, [outsider, "invalid", range()])
    end

    for operation <- [:list_suppressions, :list_overrides] do
      assert {:error, :forbidden} = apply(TrainingAnnouncements, operation, [outsider, "invalid"])

      assert {:error, :not_found} =
               apply(TrainingAnnouncements, operation, [ctx.actor, "invalid"])
    end

    {:ok, suppression} =
      TrainingAnnouncements.suppress(ctx.actor, ctx.announcement.id, range(), now: ctx.now)

    assert {:error, :forbidden} =
             TrainingAnnouncements.remove_suppression(
               outsider,
               ctx.announcement.id,
               suppression.id
             )

    assert {:error, :not_found} =
             TrainingAnnouncements.remove_override(ctx.actor, ctx.announcement.id, suppression.id)

    assert {:error, :not_found} =
             TrainingAnnouncements.remove_suppression(ctx.actor, ctx.announcement.id, "invalid")
  end

  test "suppression wins over override and removal preserves past evidence", ctx do
    {:ok, override} =
      TrainingAnnouncements.override(
        ctx.actor,
        ctx.announcement.id,
        Map.merge(range(), %{title: "Special"}),
        now: ctx.now
      )

    {:ok, suppression} =
      TrainingAnnouncements.suppress(ctx.actor, ctx.announcement.id, range(), now: ctx.now)

    assert :ok = run_due(ctx)
    delivery = Repo.one!(DiscordAnnouncementDelivery)
    assert delivery.state == "skipped"
    assert delivery.reason == "suppressed"
    assert delivery.applied_suppression_id == suppression.id
    assert delivery.applied_override_id == nil

    assert {:ok, _} =
             TrainingAnnouncements.remove_suppression(
               ctx.actor,
               ctx.announcement.id,
               suppression.id
             )

    assert {:ok, _} =
             TrainingAnnouncements.remove_override(ctx.actor, ctx.announcement.id, override.id)

    retained = Repo.get!(DiscordAnnouncementDelivery, delivery.id)
    assert retained.applied_suppression_id == nil
    assert retained.reason == "suppressed"
    assert retained.concluded_at == delivery.concluded_at
    assert :ok = run_due(ctx)
    assert Repo.one!(DiscordAnnouncementDelivery) == retained
  end

  test "worker uses override copy instead of corrupt defaults, without allowing mention or kind overrides",
       ctx do
    previous = Application.get_env(:dhc, :discord_sparring_channel_id)
    Application.put_env(:dhc, :discord_sparring_channel_id, "123456789012345678")
    on_exit(fn -> Application.put_env(:dhc, :discord_sparring_channel_id, previous) end)

    {:ok, override} =
      TrainingAnnouncements.override(
        ctx.actor,
        ctx.announcement.id,
        Map.merge(range(), %{
          title: "Special",
          message: "Safe",
          mention_everyone: true,
          kind: "roll_call"
        }),
        now: ctx.now
      )

    Repo.update_all(
      from(a in Dhc.TrainingAnnouncements.Announcement, where: a.id == ^ctx.announcement.id),
      set: [title: "{{unknown}}", message: "{{unknown}}"]
    )

    assert :ok = run_due(ctx)
    # ALE-325 will freeze/post valid copy. This driver currently leaves no row.
    assert Repo.all(DiscordAnnouncementDelivery) == []
    {:ok, _} = TrainingAnnouncements.remove_override(ctx.actor, ctx.announcement.id, override.id)
    assert :ok = run_due(ctx)
    assert %{state: "blocked", reason: "invalid_copy"} = Repo.one!(DiscordAnnouncementDelivery)

    assert {:ok, %{mention_everyone: false, kind: "sparring"}} =
             TrainingAnnouncements.get(ctx.actor, ctx.announcement.id)
  end

  test "holiday outranks both exceptions only for roll calls", ctx do
    Repo.insert!(%Holiday{
      date: ~D[2030-09-05],
      name: "Holiday",
      source_id: "h",
      fetched_at: DateTime.utc_now()
    })

    for kind <- ["roll_call", "sparring"] do
      {:ok, %{announcement: announcement}} =
        TrainingAnnouncements.create(
          ctx.actor,
          %{
            kind: kind,
            weekday: 4,
            post_time: ~T[15:00:00],
            title: "Training",
            message: "Default"
          },
          now: ctx.now
        )

      {:ok, _} =
        TrainingAnnouncements.override(
          ctx.actor,
          announcement.id,
          Map.put(range(), :title, "Special"),
          now: ctx.now
        )

      {:ok, suppression} =
        TrainingAnnouncements.suppress(ctx.actor, announcement.id, range(), now: ctx.now)

      assert :ok =
               AnnouncementWorker.perform(
                 %Oban.Job{
                   args: %{
                     "announcement_id" => announcement.id,
                     "occurrence_date" => "2030-09-05"
                   }
                 },
                 clock: fn -> ~U[2030-09-05 14:00:00.000000Z] end
               )

      delivery =
        Repo.one!(
          from(d in DiscordAnnouncementDelivery, where: d.announcement_id == ^announcement.id)
        )

      assert delivery.reason == if(kind == "roll_call", do: "holiday", else: "suppressed")

      assert delivery.applied_suppression_id ==
               if(kind == "roll_call", do: nil, else: suppression.id)

      assert delivery.applied_override_id == nil
    end
  end

  test "valid source lengths can exceed Discord limits after token expansion", ctx do
    assert {:error, changeset} =
             TrainingAnnouncements.override(
               ctx.actor,
               ctx.announcement.id,
               Map.put(range(), :message, String.duplicate("a", 1981) <> "{{date}}"),
               now: ctx.now
             )

    assert %{message: [_]} = errors_on(changeset)

    assert {:error, changeset} =
             TrainingAnnouncements.override(
               ctx.actor,
               ctx.announcement.id,
               Map.put(range(), :title, String.duplicate("a", 85) <> "{{date}}"),
               now: ctx.now
             )

    assert %{message: ["title must be at most 100 characters after rendering"]} =
             errors_on(changeset)
  end

  test "mention and inherited title expansions count toward the rendered limit", ctx do
    message = String.duplicate("a", 1991)

    {:ok, override} =
      TrainingAnnouncements.override(
        ctx.actor,
        ctx.announcement.id,
        Map.put(range(), :message, message),
        now: ctx.now
      )

    {:ok, _} = TrainingAnnouncements.remove_override(ctx.actor, ctx.announcement.id, override.id)

    {:ok, _} =
      TrainingAnnouncements.update_copy(ctx.actor, ctx.announcement.id, %{mention_everyone: true},
        now: ctx.now
      )

    assert {:error, changeset} =
             TrainingAnnouncements.override(
               ctx.actor,
               ctx.announcement.id,
               Map.put(range(), :message, message),
               now: ctx.now
             )

    assert %{message: ["message must be at most 2,000 characters after rendering"]} =
             errors_on(changeset)

    {:ok, _} =
      TrainingAnnouncements.update_copy(
        ctx.actor,
        ctx.announcement.id,
        %{title: "{{date}}", mention_everyone: false},
        now: ctx.now
      )

    assert {:error, changeset} =
             TrainingAnnouncements.override(
               ctx.actor,
               ctx.announcement.id,
               Map.put(range(), :message, String.duplicate("a", 1982) <> "{{title}}"),
               now: ctx.now
             )

    assert %{message: ["message must be at most 2,000 characters after rendering"]} =
             errors_on(changeset)
  end

  test "one-offs accept a single-date exception but not a range; removal cannot cross announcements",
       ctx do
    {:ok, %{announcement: one_off}} =
      TrainingAnnouncements.create(
        ctx.actor,
        %{
          kind: "sparring",
          one_off_date: ~D[2030-09-05],
          post_time: ~T[14:00:00],
          title: "Extra",
          message: "Extra"
        },
        now: ctx.now
      )

    for operation <- [:suppress, :override] do
      assert {:error, changeset} =
               apply(TrainingAnnouncements, operation, [
                 ctx.actor,
                 one_off.id,
                 Map.put(range(), :title, "Special"),
                 [now: ctx.now]
               ])

      assert %{to_date: [_]} = errors_on(changeset)

      assert {:ok, _} =
               apply(TrainingAnnouncements, operation, [
                 ctx.actor,
                 one_off.id,
                 %{from_date: ~D[2030-09-05], to_date: ~D[2030-09-05], title: "Special"},
                 [now: ctx.now]
               ])
    end

    {:ok, [override]} = TrainingAnnouncements.list_overrides(ctx.actor, one_off.id)

    assert {:error, :not_found} =
             TrainingAnnouncements.remove_override(ctx.actor, ctx.announcement.id, override.id)

    outsider = Dhc.MemberFixtures.member_fixture().principal_id

    assert {:error, :forbidden} =
             TrainingAnnouncements.remove_override(outsider, one_off.id, override.id)

    delivery =
      Repo.insert!(%DiscordAnnouncementDelivery{
        subject: "occurrence",
        announcement_id: one_off.id,
        occurrence_date: ~D[2030-09-05],
        state: "delivered",
        frozen_at: ctx.now,
        concluded_at: ctx.now,
        title_source: "Special",
        rendered_message: "Extra",
        applied_override_id: override.id
      })

    {:ok, _} = TrainingAnnouncements.remove_override(ctx.actor, one_off.id, override.id)

    assert Repo.get!(DiscordAnnouncementDelivery, delivery.id) == %{
             delivery
             | applied_override_id: nil
           }
  end

  test "long override ranges validate without changing the schedule or jobs", ctx do
    jobs = all_enqueued(worker: AnnouncementWorker)

    assert {:ok, _} =
             TrainingAnnouncements.override(
               ctx.actor,
               ctx.announcement.id,
               %{
                 from_date: ~D[2030-09-05],
                 to_date: ~D[9999-12-31],
                 message: "{{date}} {{title}}"
               },
               now: ctx.now
             )

    assert all_enqueued(worker: AnnouncementWorker) == jobs
  end

  defp range, do: %{from_date: ~D[2030-09-05], to_date: ~D[2030-09-12]}

  defp run_due(ctx) do
    AnnouncementWorker.perform(
      %Oban.Job{
        args: %{"announcement_id" => ctx.announcement.id, "occurrence_date" => "2030-09-05"}
      },
      clock: fn -> ~U[2030-09-05 13:00:00.000000Z] end
    )
  end

  test "a committee member can suppress a date, list it and remove it without changing jobs",
       ctx do
    jobs = all_enqueued(worker: AnnouncementWorker)

    assert {:ok, suppression} =
             TrainingAnnouncements.suppress(
               ctx.actor,
               ctx.announcement.id,
               %{from_date: ~D[2030-09-05], to_date: ~D[2030-09-05]},
               now: ctx.now
             )

    assert {:ok, [^suppression]} =
             TrainingAnnouncements.list_suppressions(ctx.actor, ctx.announcement.id)

    assert {:ok, _} =
             TrainingAnnouncements.remove_suppression(
               ctx.actor,
               ctx.announcement.id,
               suppression.id
             )

    assert {:ok, []} = TrainingAnnouncements.list_suppressions(ctx.actor, ctx.announcement.id)
    assert all_enqueued(worker: AnnouncementWorker) == jobs
  end
end
