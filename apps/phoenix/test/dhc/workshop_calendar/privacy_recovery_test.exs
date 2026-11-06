defmodule Dhc.WorkshopCalendar.PrivacyRecoveryTest do
  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  import Dhc.WorkshopCalendarTestConfig, only: [activate!: 1, deactivate!: 0]

  alias Dhc.BeginnersIntakeStripe, as: Stripe
  alias Dhc.BeginnersWorkshopFixtures, as: Fixtures
  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.{Intake, IntakePayment}
  alias Dhc.WorkshopCalendar
  alias Dhc.WorkshopCalendar.{Event, Google, Recipient}
  alias Dhc.WorkshopCalendar.Workers.SyncWorker
  alias Dhc.WorkshopCalendarHTTP, as: HTTP

  @now ~U[2026-10-22 12:00:00.000000Z]
  @early ~U[2026-11-14 19:00:00.000000Z]

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

  test "a terminal Google authorization failure retains privacy cleanup and reports once", ctx do
    Sentry.Test.setup_sentry()
    {workshop, {intake, _token}} = paid_workshop(ctx.staff)
    assert :ok = sync(workshop.id, @now)
    config = deactivate!()
    finish_and_delete!(ctx.staff, workshop.id, intake.waitlist_id)
    Agent.update(ctx.server, &%{&1 | status: 401})

    activate!(config)
    assert :ok = sync(workshop.id, @early)

    assert %{privacy_pending: true, recipient: recipient} = recipient!(intake.id)
    assert is_binary(recipient)
    assert %{failure: "unauthorized", retry_at: nil} = participant_event!(workshop.id)
    assert [%Sentry.Event{}] = Sentry.Test.pop_sentry_reports()

    assert :ok = WorkshopCalendar.repair(clock: fn -> @early end)
    assert :ok = sync(workshop.id, @early)
    assert Sentry.Test.pop_sentry_reports() == []
  end

  test "an identifier-only worker cleans a deleted person's old binding without recreating an event",
       ctx do
    {workshop, {intake, _token}} = paid_workshop(ctx.staff)
    assert :ok = sync(workshop.id, @now)
    original = participant(ctx.server)

    args = %{
      "source_kind" => "beginners_workshop",
      "source_id" => workshop.id,
      "audience" => "participant"
    }

    config = deactivate!()
    finish_and_delete!(ctx.staff, workshop.id, intake.waitlist_id)
    refute Repo.get(Dhc.Waitlist.WaitlistEntry, intake.waitlist_id)
    activate!(config)
    assert :ok = perform_job(SyncWorker, args)

    assert participant(ctx.server)["id"] == original["id"]
    assert participant(ctx.server)["attendees"] == []
    assert post_count(ctx.server) == 1
    assert %{recipient: nil, privacy_pending: false} = recipient!(intake.id)
  end

  test "refused deletion leaves the continued attendee and its privacy binding untouched", ctx do
    {workshop, {intake, _token}} = paid_workshop(ctx.staff)
    assert :ok = sync(workshop.id, @now)
    before = participant(ctx.server)
    original = recipient!(intake.id)
    assert {:ok, _} = command(ctx.staff, {:finish_workshop, workshop.id}, @early)
    next = Fixtures.scheduled_fixture(ctx.staff, %{"date" => "2026-11-21"})

    assert {:ok, _} =
             command(
               ctx.staff,
               {:fast_track, next.id, {:waitlist_entry, intake.waitlist_id}},
               @early
             )

    assert {:error, :open_intake} =
             command(ctx.staff, {:delete_person, intake.waitlist_id, %{}}, @early)

    unauthorized = Fixtures.staff_fixture("member")

    assert {:error, :forbidden} =
             command(unauthorized, {:delete_person, intake.waitlist_id, %{}}, @early)

    assert recipient!(intake.id) == original
    assert :ok = sync(workshop.id, @early)
    assert participant(ctx.server) == before
  end

  test "cancelling the full workshop can satisfy cleanup while deleting the participant event",
       ctx do
    {workshop, {intake, _token}} = paid_workshop(ctx.staff)
    assert :ok = sync(workshop.id, @now)
    event = participant(ctx.server)
    config = deactivate!()

    assert {:ok, _} =
             command(ctx.staff, {:cancel_workshop, workshop.id, %{reason: "Closed"}}, @early)

    assert {:ok, %{outcome: :deleted}} =
             command(ctx.staff, {:delete_person, intake.waitlist_id, %{refund: false}}, @early)

    assert %{privacy_pending: true} = recipient!(intake.id)
    activate!(config)
    assert :ok = sync(workshop.id, @early)
    assert HTTP.events(ctx.server)[event["id"]]["status"] == "cancelled"

    assert %{recipient: nil, previous_recipients: [], privacy_pending: false} =
             recipient!(intake.id)
  end

  defp paid_workshop(staff) do
    {workshop, [{intake, token}]} = Fixtures.contacted_fixture(staff, 1)

    assert {:ok, _} =
             BeginnersWorkshops.execute({:intake_link, token}, :start_payment,
               clock: Fixtures.clock(@now)
             )

    payment = Repo.get_by!(IntakePayment, intake_id: intake.id)

    assert {:ok, %{outcome: :paid}} =
             BeginnersWorkshops.execute(:stripe, {:complete_payment, Stripe.session(payment)},
               clock: Fixtures.clock(@now)
             )

    {workshop, {intake, token}}
  end

  defp finish_and_delete!(staff, workshop_id, waitlist_id) do
    assert {:ok, _} = command(staff, {:finish_workshop, workshop_id}, @early)

    assert {:ok, %{outcome: :deleted}} =
             command(staff, {:delete_person, waitlist_id, %{}}, @early)
  end

  defp command(staff, operation, now),
    do: BeginnersWorkshops.execute({:staff, staff}, operation, clock: Fixtures.clock(now))

  defp sync(id, now),
    do:
      WorkshopCalendar.sync(:beginners_workshop, id,
        audience: :participant,
        clock: fn -> now end
      )

  defp participant(server),
    do: HTTP.events(server) |> Map.values() |> Enum.find(&Map.has_key?(&1, "attendees"))

  defp participant_event!(id),
    do:
      Repo.get_by!(Event,
        source_kind: "beginners_workshop",
        source_id: id,
        audience: "participant"
      )

  defp recipient!(intake_id), do: Repo.get_by!(Recipient, place_id: intake_id)

  defp post_count(server), do: server |> HTTP.mutations() |> Enum.count(&(&1.method == "POST"))
end
