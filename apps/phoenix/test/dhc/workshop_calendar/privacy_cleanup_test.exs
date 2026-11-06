defmodule Dhc.WorkshopCalendar.PrivacyCleanupTest do
  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  import Dhc.WorkshopCalendarTestConfig, only: [activate!: 1, deactivate!: 0]

  alias Dhc.BeginnersIntakeStripe, as: Stripe
  alias Dhc.BeginnersWorkshopFixtures, as: Fixtures
  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.{Intake, IntakePayment}
  alias Dhc.WorkshopCalendar
  alias Dhc.WorkshopCalendar.{Event, Google, Recipient}
  alias Dhc.WorkshopCalendarHTTP, as: HTTP

  @now ~U[2026-10-22 12:00:00.000000Z]
  @ends_at ~U[2026-11-14 20:30:00.000000Z]

  setup do
    previous = WorkshopCalendar.config()

    Application.put_env(:dhc, WorkshopCalendar,
      active: true,
      committee_calendar_id: "committee@test.invalid",
      participant_calendar_id: "participants@test.invalid",
      client_id: "isolated-client",
      client_secret: "isolated-secret",
      refresh_token: "isolated-refresh",
      req_options: [plug: {Req.Test, Google}]
    )

    on_exit(fn -> Application.put_env(:dhc, WorkshopCalendar, previous) end)
    server = start_supervised!({Agent, fn -> HTTP.initial() end})
    HTTP.stub(server)
    Stripe.stub_create()
    %{server: server, staff: Fixtures.staff_fixture()}
  end

  test "hard deletion removes only the person's historical guest and disposes retained addresses",
       ctx do
    {workshop, [{removed, _}, {kept, _}]} = paid_workshop(ctx.staff, 2)
    assert :ok = sync(workshop.id, @now)
    [first] = Map.values(HTTP.events(ctx.server))
    kept_email = Repo.get!(Dhc.Waitlist.WaitlistEntry, kept.waitlist_id).email
    removed_email = Repo.get!(Dhc.Waitlist.WaitlistEntry, removed.waitlist_id).email
    accepted = %{"email" => kept_email, "responseStatus" => "accepted", "displayName" => "Kept"}

    Agent.update(ctx.server, fn state ->
      event = Map.put(first, "attendees", [%{"email" => removed_email}, accepted])
      %{state | events: Map.put(state.events, first["id"], event)}
    end)

    assert {:ok, _} = command(ctx.staff, {:finish_workshop, workshop.id}, @ends_at)
    count = length(HTTP.requests(ctx.server))

    assert {:ok, %{outcome: :deleted}} =
             command(ctx.staff, {:delete_person, removed.waitlist_id, %{}}, @ends_at)

    assert length(HTTP.requests(ctx.server)) == count
    assert Repo.get!(Intake, removed.id).waitlist_id == nil
    refute Repo.get(Dhc.Waitlist.WaitlistEntry, removed.waitlist_id)
    assert :ok = sync(workshop.id, @ends_at)
    assert HTTP.events(ctx.server)[first["id"]]["attendees"] == [accepted]
    assert HTTP.events(ctx.server)[first["id"]]["start"] == first["start"]

    assert %{recipient: nil, previous_recipients: [], active: false} =
             Repo.get_by!(Recipient, place_id: removed.id)

    acknowledgment =
      Repo.get_by!(Event, source_id: workshop.id, audience: "participant").acknowledged

    refute Map.has_key?(acknowledgment, "attendees")
    refute Jason.encode!(acknowledgment) =~ removed_email
    refute Jason.encode!(acknowledgment) =~ kept_email

    count = length(HTTP.mutations(ctx.server))
    assert :ok = sync(workshop.id, DateTime.add(@ends_at, 1))
    assert length(HTTP.mutations(ctx.server)) == count
  end

  defp paid_workshop(staff, count) do
    {workshop, people} = Fixtures.contacted_fixture(staff, count)

    for {intake, token} <- people do
      assert {:ok, _} =
               BeginnersWorkshops.execute({:intake_link, token}, :start_payment,
                 clock: Fixtures.clock(@now)
               )

      payment = Repo.get_by!(IntakePayment, intake_id: intake.id)

      assert {:ok, %{outcome: :paid}} =
               BeginnersWorkshops.execute(
                 :stripe,
                 {:complete_payment, Stripe.session(payment)},
                 clock: Fixtures.clock(@now)
               )
    end

    {workshop, people}
  end

  for missing <- [:never_created, :tombstone, :ambiguous_absence] do
    test "privacy cleanup handles #{missing} without recreating an organizer event", ctx do
      {workshop, [{intake, _}]} = paid_workshop(ctx.staff, 1)

      if unquote(missing) != :never_created do
        assert :ok = sync(workshop.id, @now)
        [event] = Map.values(HTTP.events(ctx.server))

        Agent.update(ctx.server, fn state ->
          events =
            if unquote(missing) == :tombstone,
              do: %{event["id"] => %{"id" => event["id"], "status" => "cancelled"}},
              else: %{}

          %{state | events: events}
        end)
      end

      assert {:ok, _} = command(ctx.staff, {:finish_workshop, workshop.id}, @ends_at)
      assert {:ok, _} = command(ctx.staff, {:delete_person, intake.waitlist_id, %{}}, @ends_at)
      count = length(HTTP.mutations(ctx.server))
      assert :ok = sync(workshop.id, @ends_at)
      assert length(HTTP.mutations(ctx.server)) == count
      row = Repo.get_by!(Recipient, place_id: intake.id)

      if unquote(missing) == :ambiguous_absence do
        assert row.recipient != nil
        assert row.privacy_pending
      else
        assert row.recipient == nil
        refute row.privacy_pending
      end
    end
  end

  test "inactive retention purge preserves obligations across historical workshops and partial failure",
       ctx do
    {first, [{intake, _}]} = paid_workshop(ctx.staff, 1)
    assert :ok = sync(first.id, @now)
    assert {:ok, _} = command(ctx.staff, {:finish_workshop, first.id}, @ends_at)
    next_day = ~U[2026-11-15 12:00:00.000000Z]
    second = Fixtures.scheduled_fixture(ctx.staff, %{"date" => "2026-11-21"})

    assert {:ok, %{id: second_id}} =
             command(
               ctx.staff,
               {:fast_track, second.id, {:waitlist_entry, intake.waitlist_id}},
               next_day
             )

    second_intake = Repo.get!(Intake, second_id)
    token = Dhc.BeginnersWorkshops.IntakeLink.token(second_id, second_intake.link_generation)

    assert {:ok, _} =
             BeginnersWorkshops.execute({:intake_link, token}, :start_payment,
               clock: Fixtures.clock(next_day)
             )

    payment = Repo.get_by!(IntakePayment, intake_id: second_id)

    assert {:ok, %{outcome: :paid}} =
             BeginnersWorkshops.execute(
               :stripe,
               {:complete_payment, Stripe.session(payment)},
               clock: Fixtures.clock(next_day)
             )

    assert :ok = sync(second.id, next_day)
    second_end = ~U[2026-11-21 20:30:00.000000Z]
    assert {:ok, _} = command(ctx.staff, {:finish_workshop, second.id}, second_end)
    config = deactivate!()
    requests = length(HTTP.requests(ctx.server))
    purge_at = ~U[2027-03-01 12:00:00.000000Z]

    assert %{purged: 1, failed: 0} =
             BeginnersWorkshops.run_due_passes(clock: Fixtures.clock(purge_at))

    assert Repo.get!(Intake, intake.id).waitlist_id == nil
    assert Repo.get!(Intake, second_id).waitlist_id == nil
    assert :ok = sync(first.id, purge_at)
    assert length(HTTP.requests(ctx.server)) == requests
    activate!(config)
    assert :ok = sync(first.id, purge_at)
    Agent.update(ctx.server, &%{&1 | uncertain_update: true})
    assert {:snooze, 30} = sync(second.id, purge_at)
    assert Repo.get_by!(Recipient, place_id: intake.id).recipient == nil
    assert Repo.get_by!(Recipient, place_id: second_id).recipient != nil
    assert :ok = WorkshopCalendar.repair(clock: fn -> purge_at end)
    assert :ok = sync(second.id, DateTime.add(purge_at, 30))
    assert Repo.get_by!(Recipient, place_id: second_id).recipient == nil
    assert Enum.all?(Map.values(HTTP.events(ctx.server)), &(&1["attendees"] == []))

    assert Enum.all?(
             all_enqueued(worker: Dhc.WorkshopCalendar.Workers.SyncWorker),
             &(Map.keys(&1.args) -- ~w(source_kind source_id audience) == [])
           )
  end

  for missing? <- [false, true] do
    test "unknown legacy schedule cannot strand privacy cleanup (missing event: #{missing?})",
         ctx do
      {workshop, [{intake, _}]} = paid_workshop(ctx.staff, 1)
      assert :ok = sync(workshop.id, @now)
      [event] = Map.values(HTTP.events(ctx.server))
      assert {:ok, _} = command(ctx.staff, {:finish_workshop, workshop.id}, @ends_at)
      assert {:ok, _} = command(ctx.staff, {:delete_person, intake.waitlist_id, %{}}, @ends_at)

      Repo.get!(Dhc.BeginnersWorkshops.BeginnersWorkshop, workshop.id)
      |> Ecto.Changeset.change(end_time: nil)
      |> Repo.update!()

      if unquote(missing?) do
        Agent.update(
          ctx.server,
          &%{&1 | events: %{event["id"] => %{"id" => event["id"], "status" => "cancelled"}}}
        )
      end

      assert :ok = sync(workshop.id, @ends_at)

      if not unquote(missing?) do
        assert HTTP.events(ctx.server)[event["id"]]["attendees"] == []
        assert HTTP.events(ctx.server)[event["id"]]["end"] == event["end"]
      end

      assert Repo.get_by!(Recipient, place_id: intake.id).recipient == nil
    end
  end

  defp command(staff, operation, now),
    do: BeginnersWorkshops.execute({:staff, staff}, operation, clock: Fixtures.clock(now))

  defp sync(id, now),
    do:
      WorkshopCalendar.sync(:beginners_workshop, id, audience: :participant, clock: fn -> now end)
end
