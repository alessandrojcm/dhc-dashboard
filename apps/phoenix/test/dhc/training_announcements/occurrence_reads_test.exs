defmodule Dhc.TrainingAnnouncements.OccurrenceReadsTest do
  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  alias Dhc.Repo
  alias Dhc.TrainingAnnouncements
  alias Dhc.TrainingAnnouncements.Workers.AnnouncementWorker

  setup do
    start_supervised!({Dhc.Discord.Adapter.Test, owner: self()})

    keys = [
      :discord_sparring_channel_id,
      :discord_roll_call_channel_id,
      :discord_training_announcements_channel_id,
      :discord_guild_id
    ]

    previous = Map.new(keys, &{&1, Application.fetch_env(:dhc, &1)})
    Enum.each(keys, &Application.put_env(:dhc, &1, "123456789012345678"))

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:dhc, key, value)
        {key, :error} -> Application.delete_env(:dhc, key)
      end)
    end)

    member = Dhc.MemberFixtures.member_fixture()
    Repo.insert!(%Dhc.Auth.UserRole{principal_id: member.principal_id, role: "coach"})

    Repo.insert!(%Dhc.ClubCalendar.Holiday{
      date: ~D[2030-01-01],
      name: "New Year",
      source_id: "new-year",
      fetched_at: DateTime.utc_now()
    })

    %{actor: member.principal_id, now: ~U[2030-09-05 09:00:00Z]}
  end

  test "window omits elapsed slots without evidence and keeps skipped history after re-enabling",
       %{actor: actor, now: now} do
    {:ok, %{announcement: announcement}} = TrainingAnnouncements.create(actor, attrs(), now: now)

    assert {:ok, [item]} =
             TrainingAnnouncements.occurrence_window(actor, ~D[2030-09-05], ~D[2030-09-05],
               now: now
             )

    assert item.outcome == "post"
    assert item.chain == ["disablement", "suppression", "override", "defaults"]
    assert item.rendered_message == "Come on Thursday"
    assert item.delivery == nil

    later = ~U[2030-09-05 14:00:00.000000Z]

    assert {:ok, []} =
             TrainingAnnouncements.occurrence_window(actor, ~D[2030-09-05], ~D[2030-09-05],
               now: later
             )

    TrainingAnnouncements.disable(actor, announcement.id)

    assert :ok =
             AnnouncementWorker.perform(
               %Oban.Job{
                 args: %{"announcement_id" => announcement.id, "occurrence_date" => "2030-09-05"}
               },
               clock: fn -> later end
             )

    assert {:ok, [past]} =
             TrainingAnnouncements.occurrence_window(actor, ~D[2030-09-05], ~D[2030-09-05],
               now: later
             )

    assert past.outcome == "skipped_disabled"
    assert past.chain == ["disablement"]
    assert past.delivery.state == "skipped"
    TrainingAnnouncements.enable(actor, announcement.id)

    assert {:ok, [^past]} =
             TrainingAnnouncements.occurrence_window(actor, ~D[2030-09-05], ~D[2030-09-05],
               now: later
             )
  end

  defp attrs do
    %{
      kind: "sparring",
      weekday: 4,
      post_time: ~T[14:00:00],
      title: "Training {{date}}",
      message: "Come on {{weekday}}",
      mention_everyone: false
    }
  end

  test "frozen override copy and chain survive deletion, edits and retirement; row wins even before its slot",
       %{actor: actor, now: now} do
    alias Dhc.Discord.Adapter.Test, as: Adapter
    Adapter.script(:create_message, [{:ok, %{message_id: "234567890123456789"}}])
    Adapter.script(:create_thread_from_message, [{:ok, %{thread_id: "345678901234567890"}}])
    {:ok, %{announcement: announcement}} = TrainingAnnouncements.create(actor, attrs(), now: now)

    {:ok, override} =
      TrainingAnnouncements.override(
        actor,
        announcement.id,
        %{
          from_date: ~D[2030-09-05],
          to_date: ~D[2030-09-05],
          title: "Special",
          message: "Special copy"
        },
        now: now
      )

    assert :ok = run(announcement.id, "2030-09-05", ~U[2030-09-05 14:00:00.000000Z])

    assert {:ok, item} =
             TrainingAnnouncements.get_occurrence(actor, announcement.id, ~D[2030-09-05],
               now: now
             )

    assert item.delivery.state == "delivered"
    assert item.outcome == "post_override"
    assert item.chain == ["disablement", "suppression", "override"]
    assert item.thread_name == "Special"
    assert item.rendered_message == "Special copy"
    assert item.delivery.applied_override_id == override.id
    assert item.delivery.frozen_at != nil
    assert item.delivery.message_posted_at != nil
    assert item.delivery.thread_created_at != nil

    assert item.delivery.permalink ==
             "https://discord.com/channels/123456789012345678/123456789012345678/234567890123456789"

    {:ok, _} = TrainingAnnouncements.remove_override(actor, announcement.id, override.id)

    {:ok, _} =
      TrainingAnnouncements.update_copy(actor, announcement.id, %{title: "New", message: "New"},
        now: now
      )

    {:ok, _} = TrainingAnnouncements.retire(actor, announcement.id)

    expected =
      item |> put_in([:delivery, :applied_override_id], nil) |> Map.put(:applied_override_id, nil)

    assert {:ok, [^expected]} =
             TrainingAnnouncements.occurrence_window(actor, ~D[2030-09-05], ~D[2030-09-05],
               now: ~U[2030-09-06 10:00:00Z]
             )

    assert {:ok, [^expected]} =
             TrainingAnnouncements.list_occurrences(
               actor,
               announcement.id,
               %{direction: "recent", limit: 1},
               now: ~U[2030-09-06 10:00:00Z]
             )

    assert {:ok, []} =
             TrainingAnnouncements.list_occurrences(
               actor,
               announcement.id,
               %{direction: "upcoming"},
               now: ~U[2030-09-06 10:00:00Z]
             )
  end

  test "a deleted suppression never changes the skipped resolution", %{actor: actor, now: now} do
    {:ok, %{announcement: announcement}} = TrainingAnnouncements.create(actor, attrs(), now: now)

    {:ok, suppression} =
      TrainingAnnouncements.suppress(
        actor,
        announcement.id,
        %{from_date: ~D[2030-09-05], to_date: ~D[2030-09-05]},
        now: now
      )

    assert :ok = run(announcement.id, "2030-09-05", ~U[2030-09-05 14:00:00.000000Z])
    {:ok, _} = TrainingAnnouncements.remove_suppression(actor, announcement.id, suppression.id)

    assert {:ok, [item]} =
             TrainingAnnouncements.occurrence_window(actor, ~D[2030-09-05], ~D[2030-09-05],
               now: ~U[2030-09-06 10:00:00Z]
             )

    assert item.outcome == "skipped_suppressed"
    assert item.chain == ["disablement", "suppression"]
    assert item.delivery.reason == "suppressed"
    assert item.delivery.applied_suppression_id == nil
    assert item.rendered_message == nil
  end

  test "holiday phases use send dates, ignore suppression and remain evidence after disablement",
       %{actor: actor} do
    alias Dhc.Discord.Adapter.Test, as: Adapter

    Adapter.script(:create_message, [
      {:ok, %{message_id: "234567890123456789"}},
      {:ok, %{message_id: "234567890123456790"}}
    ])

    Repo.insert!(%Dhc.ClubCalendar.Holiday{
      date: ~D[2030-09-05],
      name: "Bank holiday",
      source_id: "september",
      fetched_at: DateTime.utc_now()
    })

    early = ~U[2030-09-04 09:00:00Z]

    {:ok, %{announcement: announcement}} =
      TrainingAnnouncements.create(actor, Map.put(attrs(), :kind, "roll_call"), now: early)

    {:ok, _} =
      TrainingAnnouncements.suppress(
        actor,
        announcement.id,
        %{from_date: ~D[2030-09-05], to_date: ~D[2030-09-05]},
        now: early
      )

    assert {:ok, items} =
             TrainingAnnouncements.occurrence_window(actor, ~D[2030-09-04], ~D[2030-09-05],
               now: early
             )

    assert [
             %{date: ~D[2030-09-04], phase: "day_before"},
             %{date: ~D[2030-09-05], phase: "same_day"}
           ] = Enum.filter(items, & &1.read_only)

    for item <- Enum.filter(items, & &1.read_only) do
      assert item.holiday_date == ~D[2030-09-05]
      assert item.chain == ["holiday"]
      assert item.thread_name == nil
      assert item.rendered_message =~ "@everyone"
      assert item.rendered_message =~ "Bank holiday"
    end

    assert {:error, :not_found} =
             TrainingAnnouncements.get_occurrence(actor, announcement.id, ~D[2030-09-04],
               now: early
             )

    job = %Oban.Job{args: %{"holiday_date" => "2030-09-05", "phase" => "day_before"}}

    assert :ok =
             Dhc.TrainingAnnouncements.Workers.HolidayAnnouncementWorker.perform(job,
               clock: fn -> ~U[2030-09-04 14:00:00.000000Z] end
             )

    assert :ok = run(announcement.id, "2030-09-05", ~U[2030-09-05 14:00:00.000000Z])
    {:ok, _} = TrainingAnnouncements.disable(actor, announcement.id)

    assert {:ok, past} =
             TrainingAnnouncements.occurrence_window(actor, ~D[2030-09-04], ~D[2030-09-05],
               now: ~U[2030-09-06 09:00:00Z]
             )

    assert [_, _, _] = past
    assert Enum.count(past, &(&1.read_only and &1.delivery.state == "delivered")) == 2
    assert Enum.find(past, &(!&1.read_only)).outcome == "skipped_holiday"
  end

  test "past is rows only, the horizon is inclusive, and invalid windows fail", %{
    actor: actor,
    now: now
  } do
    {:ok, %{announcement: announcement}} = TrainingAnnouncements.create(actor, attrs(), now: now)

    assert {:ok, []} =
             TrainingAnnouncements.occurrence_window(actor, ~D[2030-08-29], ~D[2030-08-29],
               now: now
             )

    assert {:error, :not_found} =
             TrainingAnnouncements.get_occurrence(actor, announcement.id, ~D[2030-09-05],
               now: ~U[2030-09-05 14:00:00Z]
             )

    horizon = TrainingAnnouncements.retention_horizon(~D[2030-09-05])
    assert {:ok, []} = TrainingAnnouncements.occurrence_window(actor, horizon, horizon, now: now)

    for {first, last} <- [
          {Date.add(horizon, -1), horizon},
          {~D[2030-09-05], ~D[2030-11-06]},
          {~D[2030-09-06], ~D[2030-09-05]},
          {"bad", nil}
        ] do
      assert {:error, _} = TrainingAnnouncements.occurrence_window(actor, first, last, now: now)
    end

    assert {:ok, _} =
             TrainingAnnouncements.occurrence_window(actor, ~D[2030-09-05], ~D[2030-11-05],
               now: now
             )

    member = Dhc.MemberFixtures.member_fixture()

    assert {:error, :forbidden} =
             TrainingAnnouncements.occurrence_window(member.principal_id, "bad", nil, now: now)
  end

  test "window bulk-loads exceptions for all announcements", %{actor: actor, now: now} do
    for suffix <- 1..3 do
      announcement_attrs =
        attrs()
        |> Map.put(:title, "Training #{suffix}")
        |> Map.put(:message, "Come on {{weekday}} #{suffix}")

      assert {:ok, _} = TrainingAnnouncements.create(actor, announcement_attrs, now: now)
    end

    handler_id = {__MODULE__, self()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:dhc, :repo, :query],
        &__MODULE__.forward_query/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, items} =
             TrainingAnnouncements.occurrence_window(actor, ~D[2030-09-05], ~D[2030-09-05],
               now: now
             )

    assert [_, _, _] = Enum.reject(items, & &1.read_only)

    queries = receive_queries([])

    assert Enum.count(
             queries,
             &String.contains?(&1, ~s(FROM "training_announcement_suppressions"))
           ) ==
             1

    assert Enum.count(queries, &String.contains?(&1, ~s(FROM "training_announcement_overrides"))) ==
             1
  end

  defp run(id, date, now) do
    AnnouncementWorker.perform(
      %Oban.Job{args: %{"announcement_id" => id, "occurrence_date" => date}},
      clock: fn -> now end
    )
  end

  defp receive_queries(queries) do
    receive do
      {:repo_query, query} -> receive_queries([query | queries])
    after
      0 -> queries
    end
  end

  def forward_query(_event, _measurements, metadata, test_pid) do
    send(test_pid, {:repo_query, metadata.query})
  end

  test "invalid projected holiday copy is an inspector error rather than a failed calendar read",
       %{actor: actor, now: now} do
    Repo.insert!(%Dhc.ClubCalendar.Holiday{
      date: ~D[2030-09-12],
      name: String.duplicate("x", 2001),
      source_id: "invalid",
      fetched_at: DateTime.utc_now()
    })

    {:ok, _} = TrainingAnnouncements.create(actor, Map.put(attrs(), :kind, "roll_call"), now: now)

    assert {:ok, items} =
             TrainingAnnouncements.occurrence_window(actor, ~D[2030-09-11], ~D[2030-09-12],
               now: now
             )

    assert [before, same_day] = Enum.filter(items, & &1.read_only)

    for item <- [before, same_day] do
      assert [_ | _] = item.render_errors
      assert item.rendered_message == nil
    end
  end

  test "rail upcoming lists the Holiday Announcements only the driving roll call sends", %{
    actor: actor,
    now: now
  } do
    Repo.insert!(%Dhc.ClubCalendar.Holiday{
      date: ~D[2030-09-12],
      name: "Thursday holiday",
      source_id: "thursday",
      fetched_at: DateTime.utc_now()
    })

    roll_call = Map.put(attrs(), :kind, "roll_call")

    {:ok, %{announcement: driver}} = TrainingAnnouncements.create(actor, roll_call, now: now)

    {:ok, %{announcement: later}} =
      TrainingAnnouncements.create(actor, %{roll_call | post_time: ~T[18:00:00]}, now: now)

    {:ok, %{announcement: sparring}} = TrainingAnnouncements.create(actor, attrs(), now: now)

    {:ok, items} =
      TrainingAnnouncements.list_occurrences(actor, driver.id, %{limit: 4}, now: now)

    assert [
             %{subject: "occurrence", date: ~D[2030-09-05], outcome: "post"},
             %{subject: "holiday", date: ~D[2030-09-11], phase: "day_before"},
             %{subject: "holiday", date: ~D[2030-09-12], phase: "same_day"},
             %{subject: "occurrence", date: ~D[2030-09-12], outcome: "skipped_holiday"}
           ] = items

    for notice <- Enum.filter(items, &(&1.subject == "holiday")) do
      assert notice.holiday_date == ~D[2030-09-12]
      assert notice.read_only
      assert notice.post_time == ~T[14:00:00]
      assert notice.rendered_message =~ "Thursday holiday"
    end

    for other <- [later, sparring] do
      {:ok, items} =
        TrainingAnnouncements.list_occurrences(actor, other.id, %{limit: 4}, now: now)

      refute Enum.any?(items, &(&1.subject == "holiday"))
    end

    # Pausing the driver hands the notices to the next enabled roll call.
    {:ok, _} = TrainingAnnouncements.disable(actor, driver.id)

    {:ok, items} = TrainingAnnouncements.list_occurrences(actor, later.id, %{limit: 4}, now: now)

    assert [%{post_time: ~T[18:00:00]}, %{post_time: ~T[18:00:00]}] =
             Enum.filter(items, &(&1.subject == "holiday"))

    {:ok, items} =
      TrainingAnnouncements.list_occurrences(actor, driver.id, %{limit: 4}, now: now)

    refute Enum.any?(items, &(&1.subject == "holiday"))

    assert {:ok, []} =
             TrainingAnnouncements.list_occurrences(actor, later.id, %{direction: "recent"},
               now: now
             )
  end

  test "a one-off roll call on a bank holiday lists its day-before notice", %{
    actor: actor
  } do
    now = ~U[2029-12-20 09:00:00Z]

    {:ok, %{announcement: one_off}} =
      TrainingAnnouncements.create(
        actor,
        attrs()
        |> Map.merge(%{kind: "roll_call", weekday: nil, one_off_date: ~D[2030-01-01]}),
        now: now
      )

    assert {:ok,
            [
              %{subject: "holiday", date: ~D[2029-12-31], phase: "day_before"},
              %{subject: "holiday", date: ~D[2030-01-01], phase: "same_day"},
              %{subject: "occurrence", date: ~D[2030-01-01], outcome: "skipped_holiday"}
            ]} =
             TrainingAnnouncements.list_occurrences(actor, one_off.id, %{limit: 5}, now: now)
  end

  test "rail includes a distant one-off and honours direction and limit", %{
    actor: actor,
    now: now
  } do
    {:ok, %{announcement: one_off}} =
      TrainingAnnouncements.create(
        actor,
        attrs() |> Map.merge(%{weekday: nil, one_off_date: ~D[2030-12-05]}),
        now: now
      )

    assert {:ok, [%{date: ~D[2030-12-05]}]} =
             TrainingAnnouncements.list_occurrences(
               actor,
               one_off.id,
               %{direction: "upcoming", limit: 1},
               now: now
             )

    {:ok, %{announcement: weekly}} = TrainingAnnouncements.create(actor, attrs(), now: now)

    assert {:ok, [%{date: ~D[2030-09-05]}, %{date: ~D[2030-09-12]}]} =
             TrainingAnnouncements.list_occurrences(actor, weekly.id, %{limit: 2}, now: now)

    assert {:ok, []} =
             TrainingAnnouncements.list_occurrences(actor, weekly.id, %{direction: "recent"},
               now: now
             )

    for params <- [%{limit: 0}, %{limit: 51}, %{direction: "backwards"}, %{limit: "bad"}] do
      assert {:error, _} =
               TrainingAnnouncements.list_occurrences(actor, weekly.id, params, now: now)
    end
  end
end
