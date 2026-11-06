defmodule Dhc.WorkshopCalendar.BeginnersParticipantTest do
  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  alias Dhc.BeginnersIntakeStripe, as: Stripe
  alias Dhc.BeginnersWorkshopFixtures, as: Fixtures
  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.{Intake, IntakePayment}
  alias Dhc.WorkshopCalendar
  alias Dhc.WorkshopCalendar.Google
  alias Dhc.WorkshopCalendar.Workers.SyncWorker
  alias Dhc.WorkshopCalendarHTTP, as: HTTP

  @now ~U[2026-10-22 12:00:00.000000Z]
  @ends_at ~U[2026-11-14 20:30:00Z]

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

  test "Stripe confirmation retains the person's address, not payer or later edits; return/webhook replays are silent",
       %{staff: staff, server: server} do
    {workshop, [{intake, token}]} =
      Fixtures.contacted_fixture(staff, 1, %{
        "date" => "2027-03-28",
        "start_time" => "10:00",
        "end_time" => "12:00"
      })

    person = Repo.get!(Dhc.Waitlist.WaitlistEntry, intake.waitlist_id)
    payment = hold!(intake, token)

    session =
      Stripe.session(payment, %{
        "customer_email" => "payer@example.com",
        "customer_details" => %{"email" => "guardian@example.com", "name" => "PRIVATE"}
      })

    assert {:ok, %{outcome: :paid}} = complete(session)
    assert HTTP.requests(server) == []

    person |> Ecto.Changeset.change(email: "changed@example.com") |> Repo.update!()
    Stripe.stub_retrieve(session)
    assert {:ok, %{outcome: :already_recorded}} = complete(session["id"])
    assert {:ok, %{outcome: :already_recorded}} = complete(session)

    args = %{
      "source_kind" => "beginners_workshop",
      "source_id" => workshop.id,
      "audience" => "participant"
    }

    assert_enqueued(worker: SyncWorker, args: args)
    assert :ok = perform_job(SyncWorker, args)
    event = participant(server)
    assert event["attendees"] == [%{"email" => person.email}]
    assert event["summary"] == "Beginners' Workshop"
    assert event["start"]["dateTime"] == "2027-03-28T09:00:00Z"
    assert event["end"]["dateTime"] == "2027-03-28T11:00:00Z"
    assert event["visibility"] == "private"
    assert event["guestsCanSeeOtherGuests"] == false
    assert event["guestsCanInviteOthers"] == false
    assert event["guestsCanModify"] == false

    assert Map.keys(event) |> Enum.sort() ==
             ~w(attendees end etag guestsCanInviteOthers guestsCanModify guestsCanSeeOtherGuests id location start status summary visibility)

    count = length(HTTP.mutations(server))
    assert :ok = perform_job(SyncWorker, args)
    assert length(HTTP.mutations(server)) == count
    assert :ok = WorkshopCalendar.sync(:beginners_workshop, workshop.id, clock: fn -> @now end)

    [committee] =
      HTTP.events(server) |> Map.values() |> Enum.reject(&Map.has_key?(&1, "attendees"))

    refute committee["id"] == event["id"]
    refute Jason.encode!(committee) =~ person.email
    refute Jason.encode!(HTTP.mutations(server)) =~ "payer@example.com"
    refute Jason.encode!(HTTP.mutations(server)) =~ "/beginners/intake/"

    assert Enum.all?(
             all_enqueued(worker: SyncWorker),
             &(Map.keys(&1.args) -- ~w(source_kind source_id audience) == [])
           )
  end

  test "cancel with refund removes a confirmed place while its refund is still pending", %{
    staff: staff,
    server: server
  } do
    {workshop, [{intake, token}]} = Fixtures.contacted_fixture(staff, 1)
    assert {:ok, %{outcome: :paid}} = intake |> hold!(token) |> Stripe.session() |> complete()
    assert :ok = sync(workshop.id)
    first = participant(server)
    assert [_] = first["attendees"]
    assert {:ok, _} = command(staff, {:cancel_with_refund, workshop.id, intake.id, %{}})
    assert :ok = sync(workshop.id, @ends_at)
    assert participant(server)["id"] == first["id"]
    assert participant(server)["attendees"] == []
    assert [%{status: "pending"}] = Repo.all(Dhc.BeginnersWorkshops.IntakeRefund)
    assert Repo.get!(Intake, intake.id).state == "cancelled_refunded"
  end

  for operation <- [:defer, :withdraw] do
    test "#{operation} records removal before any Google work or refund completion", %{
      staff: staff,
      server: server
    } do
      {workshop, [{intake, token}]} = Fixtures.contacted_fixture(staff, 1)
      assert {:ok, %{outcome: :paid}} = intake |> hold!(token) |> Stripe.session() |> complete()
      assert :ok = sync(workshop.id)
      count = length(HTTP.requests(server))
      assert :ok = WorkshopCalendar.pause()

      assert {:ok, _} =
               command(staff, {unquote(operation), workshop.id, intake.id, %{refund: true}})

      assert :ok = sync(workshop.id)
      assert length(HTTP.requests(server)) == count
      assert :ok = WorkshopCalendar.resume()
      assert :ok = sync(workshop.id, @ends_at)
      assert participant(server)["attendees"] == []

      assert {:ok, %{outcome: :already_recorded}} =
               complete(Stripe.session(Repo.get_by!(IntakePayment, intake_id: intake.id)))

      assert :ok = sync(workshop.id, @ends_at)
      assert participant(server)["attendees"] == []
    end
  end

  test "cancellation cancels the participant event but keeps committee time and presentation, even after end",
       %{staff: staff, server: server} do
    {workshop, [{intake, token}]} = Fixtures.contacted_fixture(staff, 1)
    assert {:ok, %{outcome: :paid}} = intake |> hold!(token) |> Stripe.session() |> complete()
    assert :ok = sync(workshop.id)
    first = participant(server)
    assert :ok = WorkshopCalendar.sync(:beginners_workshop, workshop.id, clock: fn -> @now end)
    assert {:ok, _} = command(staff, {:cancel_workshop, workshop.id, %{reason: "PRIVATE"}})
    assert :ok = sync(workshop.id, @ends_at)
    assert HTTP.events(server)[first["id"]]["status"] == "cancelled"

    assert :ok =
             WorkshopCalendar.sync(:beginners_workshop, workshop.id, clock: fn -> @ends_at end)

    committee =
      HTTP.events(server)
      |> Map.values()
      |> Enum.find(&(&1["summary"] == "[Cancelled] Beginners' Workshop"))

    assert committee["start"] == first["start"]
    assert committee["end"] == first["end"]
    refute Jason.encode!(committee) =~ "PRIVATE"
    assert [%{status: "held"}] = Repo.all(Dhc.BeginnersWorkshops.CarriedFee)
  end

  test "contact, open hold, unpaid, failed checkout and compensating completion never qualify", %{
    staff: staff,
    server: server
  } do
    {workshop, [{intake, token}]} = Fixtures.contacted_fixture(staff, 1)
    assert :ok = sync(workshop.id)
    assert HTTP.mutations(server) == []
    Stripe.fail_create(503)

    assert {:error, :payment_unavailable} =
             BeginnersWorkshops.execute({:intake_link, token}, :start_payment,
               clock: Fixtures.clock(@now)
             )

    Stripe.stub_create()
    payment = hold!(intake, token)
    assert :ok = sync(workshop.id)
    assert HTTP.mutations(server) == []

    assert {:ok, %{outcome: :not_paid}} =
             complete(Stripe.session(payment, %{"payment_status" => "unpaid"}))

    assert :ok = sync(workshop.id)
    assert HTTP.mutations(server) == []

    assert {:ok, %{outcome: :policy_failed}} =
             complete(Stripe.session(payment, %{"amount_total" => 1}))

    assert :ok = sync(workshop.id)
    assert HTTP.mutations(server) == []
    assert Repo.get!(Intake, intake.id).state == "contacted"

    assert [%{reason: "policy_failed", status: "pending"}] =
             Repo.all(Dhc.BeginnersWorkshops.IntakeRefund)

    refute_enqueued(worker: SyncWorker, args: %{audience: "participant"})
  end

  test "completion after a withdrawn offer compensates without an invitation", %{
    staff: staff,
    server: server
  } do
    {workshop, [{intake, token}]} = Fixtures.contacted_fixture(staff, 1)
    payment = hold!(intake, token)
    assert {:ok, _} = command(staff, {:withdraw, workshop.id, intake.id, %{}})
    assert {:ok, %{outcome: :paid_after_close}} = complete(Stripe.session(payment))
    assert :ok = sync(workshop.id)
    assert HTTP.mutations(server) == []
  end

  test "reschedule preserves RSVP on the existing identity; no-op and internal updates send nothing",
       %{staff: staff, server: server} do
    {workshop, [{intake, token}]} = Fixtures.contacted_fixture(staff, 1)
    assert {:ok, %{outcome: :paid}} = intake |> hold!(token) |> Stripe.session() |> complete()
    assert :ok = sync(workshop.id)
    first = participant(server)
    guest = first["attendees"] |> hd() |> Map.put("responseStatus", "declined")

    Agent.update(
      server,
      &%{&1 | events: Map.put(&1.events, first["id"], Map.put(first, "attendees", [guest]))}
    )

    count = length(HTTP.mutations(server))
    assert :ok = sync(workshop.id)
    assert {:ok, _} = command(staff, {:update_workshop, workshop.id, %{capacity: 20}})
    assert :ok = sync(workshop.id)
    assert length(HTTP.mutations(server)) == count
    assert Repo.get!(Intake, intake.id).state == "paid"

    assert {:ok, _} =
             command(
               staff,
               {:reschedule_workshop, workshop.id,
                %{date: "2027-03-28", start_time: "10:00", end_time: "12:00", venue: "New hall"}}
             )

    assert :ok = sync(workshop.id)
    moved = participant(server)
    assert moved["id"] == first["id"]
    assert moved["attendees"] == [guest]
    assert moved["start"]["dateTime"] == "2027-03-28T09:00:00Z"
    assert moved["end"]["dateTime"] == "2027-03-28T11:00:00Z"
    assert moved["location"] == "New hall"
    assert List.last(HTTP.mutations(server)).query == "sendUpdates=all"
  end

  test "early finalisation, check-in and later attendance corrections preserve historical invitations",
       %{staff: staff, server: server} do
    {workshop, intakes} = Fixtures.contacted_fixture(staff, 2)

    for {intake, token} <- intakes,
        do:
          assert(
            {:ok, %{outcome: :paid}} = intake |> hold!(token) |> Stripe.session() |> complete()
          )

    [{attended, _}, {absent, _}] = intakes
    assert :ok = sync(workshop.id)
    first = participant(server)
    count = length(HTTP.mutations(server))
    early = ~U[2026-11-14 19:00:00Z]
    assert {:ok, _} = command(staff, {:check_in, workshop.id, attended.id}, early)
    assert {:ok, _} = command(staff, {:finish_workshop, workshop.id}, early)
    assert :ok = sync(workshop.id, early)
    assert length(HTTP.mutations(server)) == count

    for to <- ["attended", "no_show", "deferred"] do
      assert {:ok, _} =
               command(
                 staff,
                 {:correct_attendance, workshop.id, absent.id, %{to: to}},
                 ~U[2026-11-15 09:00:00Z]
               )

      assert :ok = sync(workshop.id, ~U[2026-11-15 09:00:00Z])
      assert participant(server) == first
    end

    assert length(HTTP.mutations(server)) == count
    assert Repo.get!(Intake, absent.id).state == "deferred"
  end

  test "the exact end blocks first invites and missing-event recreation", %{
    staff: staff,
    server: server
  } do
    {workshop, [{intake, token}]} = Fixtures.contacted_fixture(staff, 1)
    assert {:ok, %{outcome: :paid}} = intake |> hold!(token) |> Stripe.session() |> complete()
    assert :ok = sync(workshop.id, @ends_at)
    assert HTTP.mutations(server) == []
    assert :ok = sync(workshop.id)
    first = participant(server)

    Agent.update(
      server,
      &%{&1 | events: %{first["id"] => %{"id" => first["id"], "status" => "cancelled"}}}
    )

    count = length(HTTP.mutations(server))
    assert :ok = sync(workshop.id, @ends_at)
    assert length(HTTP.mutations(server)) == count
    assert :ok = sync(workshop.id, DateTime.add(@ends_at, -1))
    recreated = participant(server)
    refute recreated["id"] == first["id"]
    assert [_] = recreated["attendees"]
  end

  test "invalid and Google-rejected recipients get per-person follow-up while valid additions and removals progress",
       %{staff: staff, server: server} do
    outsider = Fixtures.staff_fixture("workshop_coordinator")

    {workshop,
     [
       {removed, removed_token},
       {invalid, invalid_token},
       {rejected, rejected_token},
       {valid, valid_token}
     ]} = Fixtures.contacted_fixture(staff, 4)

    assert {:ok, %{outcome: :paid}} =
             removed |> hold!(removed_token) |> Stripe.session() |> complete()

    assert :ok = sync(workshop.id)
    invalid_payment = hold!(invalid, invalid_token)
    person = Repo.get!(Dhc.Waitlist.WaitlistEntry, invalid.waitlist_id)
    person |> Ecto.Changeset.change(email: "not-an-address") |> Repo.update!()
    assert {:ok, %{outcome: :paid}} = invalid_payment |> Stripe.session() |> complete()

    for {intake, token} <- [{rejected, rejected_token}, {valid, valid_token}] do
      assert {:ok, %{outcome: :paid}} = intake |> hold!(token) |> Stripe.session() |> complete()
    end

    rejected_email = Repo.get!(Dhc.Waitlist.WaitlistEntry, rejected.waitlist_id).email
    valid_email = Repo.get!(Dhc.Waitlist.WaitlistEntry, valid.waitlist_id).email
    Agent.update(server, &%{&1 | rejected_recipients: [rejected_email]})
    assert {:ok, _} = command(staff, {:cancel_with_refund, workshop.id, removed.id, %{}})
    assert :ok = sync(workshop.id)
    assert participant(server)["attendees"] == [%{"email" => valid_email}]
    assert {:ok, %{notifications: notifications}} = Dhc.Notifications.list_for_user(staff)
    alerts = Enum.filter(notifications, &String.starts_with?(&1.body, "Calendar Invitation"))
    assert [_, _] = alerts
    assert Enum.all?(alerts, &(&1.body =~ "Workshop places are unchanged"))
    assert Enum.all?(alerts, &(&1.body =~ "recorded address"))
    assert {:ok, %{notifications: []}} = Dhc.Notifications.list_for_user(outsider)
    count = length(HTTP.mutations(server))
    Repo.delete_all(Dhc.Notifications.Notification)
    assert :ok = WorkshopCalendar.repair(clock: fn -> @now end)
    assert :ok = sync(workshop.id)
    assert length(HTTP.mutations(server)) == count
    assert {:ok, %{notifications: []}} = Dhc.Notifications.list_for_user(staff)
  end

  test "Google outages cannot undo payment and retry recovers without duplicate invitations", %{
    staff: staff,
    server: server
  } do
    {workshop, [{intake, token}]} = Fixtures.contacted_fixture(staff, 1)
    Agent.update(server, &%{&1 | status: 503})
    assert {:ok, %{outcome: :paid}} = intake |> hold!(token) |> Stripe.session() |> complete()
    assert {:snooze, 30} = sync(workshop.id)
    assert Repo.get!(Intake, intake.id).state == "paid"
    Agent.update(server, &%{&1 | status: nil, uncertain_update: true})
    assert {:snooze, 60} = sync(workshop.id, DateTime.add(@now, 30))
    assert :ok = sync(workshop.id, DateTime.add(@now, 90))
    assert [_] = participant(server)["attendees"]
    assert [_create, _add] = HTTP.mutations(server)
  end

  test "paused manual address repair updates the retained binding and cannot restore the old address",
       %{staff: staff, server: server} do
    {workshop, [{intake, token}]} = Fixtures.contacted_fixture(staff, 1)
    assert {:ok, %{outcome: :paid}} = intake |> hold!(token) |> Stripe.session() |> complete()
    assert :ok = sync(workshop.id)

    assert {:error, :pause_required} =
             WorkshopCalendar.correct_recipient(
               :beginners_workshop,
               workshop.id,
               intake.id,
               "corrected@example.com"
             )

    assert :ok = WorkshopCalendar.pause()

    assert :ok =
             WorkshopCalendar.correct_recipient(
               :beginners_workshop,
               workshop.id,
               intake.id,
               "corrected@example.com"
             )

    assert :ok = WorkshopCalendar.resume()
    assert :ok = sync(workshop.id)
    assert participant(server)["attendees"] == [%{"email" => "corrected@example.com"}]
    assert :ok = sync(workshop.id)
    assert participant(server)["attendees"] == [%{"email" => "corrected@example.com"}]
  end

  test "a new paid place after cancellation is a new entitlement, unlike a Google-only decline",
       %{staff: staff, server: server} do
    {workshop, [{intake, token}]} = Fixtures.contacted_fixture(staff, 1)
    assert {:ok, %{outcome: :paid}} = intake |> hold!(token) |> Stripe.session() |> complete()
    assert :ok = sync(workshop.id)
    first = participant(server)
    guest = hd(first["attendees"]) |> Map.put("responseStatus", "declined")

    Agent.update(
      server,
      &%{&1 | events: Map.put(&1.events, first["id"], Map.put(first, "attendees", [guest]))}
    )

    count = length(HTTP.mutations(server))
    assert :ok = sync(workshop.id)
    assert length(HTTP.mutations(server)) == count
    assert :ok = WorkshopCalendar.pause()
    assert {:ok, _} = command(staff, {:cancel_with_refund, workshop.id, intake.id, %{}})

    assert {:ok, %{id: new_id}} =
             command(staff, {:fast_track, workshop.id, {:waitlist_entry, intake.waitlist_id}})

    refute new_id == intake.id
    replacement = Repo.get!(Intake, new_id)
    new_token = Dhc.BeginnersWorkshops.IntakeLink.token(new_id, replacement.link_generation)

    assert {:ok, %{outcome: :paid}} =
             replacement |> hold!(new_token) |> Stripe.session() |> complete()

    assert :ok = WorkshopCalendar.resume()
    assert :ok = sync(workshop.id)
    assert participant(server)["id"] == first["id"]
    assert participant(server)["attendees"] == [%{"email" => guest["email"]}]
  end

  test "missing recorded recipient is follow-up, never a payer fallback", %{
    staff: staff,
    server: server
  } do
    {workshop, [{intake, token}]} = Fixtures.contacted_fixture(staff, 1)
    payment = hold!(intake, token)

    Repo.get!(Dhc.Waitlist.WaitlistEntry, intake.waitlist_id)
    |> Ecto.Changeset.change(email: "")
    |> Repo.update!()

    assert {:ok, %{outcome: :paid}} =
             complete(Stripe.session(payment, %{"customer_email" => "payer@example.com"}))

    assert :ok = sync(workshop.id)
    assert HTTP.mutations(server) == []
    assert {:ok, %{notifications: notifications}} = Dhc.Notifications.list_for_user(staff)
    assert Enum.any?(notifications, &(&1.body =~ "recorded address"))
    assert Repo.get!(Intake, intake.id).state == "paid"
  end

  test "terminal Google failure alerts only Beginners' Workshop recipients once and never changes confirmation",
       %{staff: staff, server: server} do
    outsider = Fixtures.staff_fixture("workshop_coordinator")
    {workshop, [{intake, token}]} = Fixtures.contacted_fixture(staff, 1)
    assert {:ok, %{outcome: :paid}} = intake |> hold!(token) |> Stripe.session() |> complete()
    Agent.update(server, &%{&1 | status: 401})
    assert :ok = sync(workshop.id)
    assert {:ok, %{notifications: notifications}} = Dhc.Notifications.list_for_user(staff)

    assert Enum.count(
             notifications,
             &(&1.body =~ "authorization" and &1.body =~ "Workshop places are unchanged")
           ) == 1

    assert {:ok, %{notifications: []}} = Dhc.Notifications.list_for_user(outsider)
    Repo.delete_all(Dhc.Notifications.Notification)
    count = length(HTTP.requests(server))
    assert :ok = WorkshopCalendar.repair(clock: fn -> @now end)
    assert :ok = sync(workshop.id)
    assert length(HTTP.requests(server)) == count
    assert {:ok, %{notifications: []}} = Dhc.Notifications.list_for_user(staff)
    assert Repo.get!(Intake, intake.id).state == "paid"
  end

  defp command(staff, operation, now \\ @now),
    do:
      BeginnersWorkshops.execute({:staff, staff}, operation,
        clock: Fixtures.clock(%{now | microsecond: {0, 6}})
      )

  defp complete(session, now \\ @now),
    do:
      BeginnersWorkshops.execute(:stripe, {:complete_payment, session},
        clock: Fixtures.clock(now)
      )

  defp hold!(intake, token) do
    assert {:ok, _} =
             BeginnersWorkshops.execute({:intake_link, token}, :start_payment,
               clock: Fixtures.clock(@now)
             )

    Repo.get_by!(IntakePayment, intake_id: intake.id)
  end

  defp sync(id, now \\ @now),
    do:
      WorkshopCalendar.sync(:beginners_workshop, id, audience: :participant, clock: fn -> now end)

  defp participant(server),
    do: HTTP.events(server) |> Map.values() |> Enum.find(&Map.has_key?(&1, "attendees"))
end
