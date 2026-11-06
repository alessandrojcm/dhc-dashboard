defmodule Dhc.WorkshopCalendar.BeginnersCreditTest do
  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  alias Dhc.BeginnersIntakeStripe, as: Stripe
  alias Dhc.BeginnersWorkshopFixtures, as: Fixtures
  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.{Intake, IntakeLink, IntakePayment}
  alias Dhc.WorkshopCalendar
  alias Dhc.WorkshopCalendar.Google
  alias Dhc.WorkshopCalendar.Workers.SyncWorker
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
    %{server: server, staff: Fixtures.staff_fixture()}
  end

  test "the person's credit confirmation retains their address, not the original payer, before delayed Calendar work",
       %{
         staff: staff,
         server: server
       } do
    person = stripe_paid_credit_holder!(staff)

    workshop =
      Fixtures.scheduled_fixture(staff, %{
        "date" => "2027-03-28",
        "start_time" => "10:00",
        "end_time" => "12:00"
      })

    {intake, token} = contact!(staff, workshop, person)
    assert {:ok, %{outcome: :done}} = execute({:intake_link, token}, :confirm)
    assert HTTP.requests(server) == []
    person |> Ecto.Changeset.change(email: "changed@example.com") |> Repo.update!()

    args = %{
      "source_kind" => "beginners_workshop",
      "source_id" => workshop.id,
      "audience" => "participant"
    }

    assert_enqueued(worker: SyncWorker, args: args)
    assert :ok = perform_job(SyncWorker, args)
    assert [event] = Map.values(HTTP.events(server))
    assert event["attendees"] == [%{"email" => person.email}]
    refute Jason.encode!(HTTP.mutations(server)) =~ "payer@example.com"
    refute Jason.encode!(HTTP.mutations(server)) =~ "guardian@example.com"
    assert event["summary"] == "Beginners' Workshop"
    assert event["start"]["dateTime"] == "2027-03-28T09:00:00Z"
    assert event["end"]["dateTime"] == "2027-03-28T11:00:00Z"
    assert event["location"] == "St. Andrew's Hall"
    assert event["visibility"] == "private"
    assert event["guestsCanSeeOtherGuests"] == false
    assert event["guestsCanInviteOthers"] == false
    assert event["guestsCanModify"] == false

    assert Map.keys(event) |> Enum.sort() ==
             ~w(attendees end etag guestsCanInviteOthers guestsCanModify guestsCanSeeOtherGuests id location start status summary visibility)

    assert BeginnersWorkshops.calendar_place_ids(workshop.id) == [intake.id]

    assert Enum.all?(
             all_enqueued(worker: SyncWorker),
             &(Map.keys(&1.args) -- ~w(source_kind source_id audience) == [])
           )
  end

  test "staff confirmation shares Stripe's projection and replays never reset an RSVP or select a new address",
       %{
         staff: staff,
         server: server
       } do
    credit_person = holder!()
    stripe_person = Fixtures.waiting_person_fixture(~U[2025-01-02 12:00:00Z])
    workshop = Fixtures.scheduled_fixture(staff)
    {credit, token} = contact!(staff, workshop, credit_person)
    {stripe, stripe_token} = contact!(staff, workshop, stripe_person)
    assert {:ok, %{outcome: :done}} = command(staff, {:confirm, workshop.id, credit.id, %{}})
    pay!(stripe, stripe_token)
    assert :ok = sync(workshop.id)
    first = participant(server)

    assert Enum.sort(first["attendees"]) ==
             Enum.sort([%{"email" => credit_person.email}, %{"email" => stripe_person.email}])

    guests = Enum.map(first["attendees"], &Map.put(&1, "responseStatus", "declined"))

    Agent.update(server, fn state ->
      %{state | events: Map.put(state.events, first["id"], Map.put(first, "attendees", guests))}
    end)

    count = length(HTTP.mutations(server))
    credit_person |> Ecto.Changeset.change(email: "changed@example.com") |> Repo.update!()
    assert {:ok, %{outcome: :already_done}} = execute({:intake_link, token}, :confirm)

    assert {:ok, %{outcome: :already_done}} =
             command(staff, {:confirm, workshop.id, credit.id, %{}})

    assert :ok = sync(workshop.id)
    assert participant(server)["attendees"] == guests
    assert length(HTTP.mutations(server)) == count

    assert {:ok, %{workshop: %{seats: %{paid: 2}}}} =
             BeginnersWorkshops.workshop_console(workshop.id, clock: Fixtures.clock(@now))
  end

  test "held credit, contact and refused confirmations cannot create an invitation", %{
    staff: staff,
    server: server
  } do
    person = holder!()
    workshop = Fixtures.scheduled_fixture(staff, %{"capacity" => 1})
    assert :ok = sync(workshop.id)
    assert HTTP.mutations(server) == []
    {intake, token} = contact!(staff, workshop, person)
    assert :ok = sync(workshop.id)
    assert HTTP.mutations(server) == []
    outsider = Fixtures.staff_fixture("coach")
    assert {:error, :forbidden} = command(outsider, {:confirm, workshop.id, intake.id, %{}})
    assert {:error, :not_found} = execute({:intake_link, "not-a-token"}, :confirm)

    payer = Fixtures.waiting_person_fixture(~U[2025-01-02 12:00:00Z])
    {payer_intake, payer_token} = contact!(staff, workshop, payer)
    assert {:error, :no_carried_fee} = execute({:intake_link, payer_token}, :confirm)
    assert :ok = sync(workshop.id)
    assert HTTP.mutations(server) == []
    pay!(payer_intake, payer_token)
    assert {:error, :full} = execute({:intake_link, token}, :confirm)
    assert {:error, :full} = command(staff, {:confirm, workshop.id, intake.id, %{}})
    assert :ok = sync(workshop.id)
    assert participant(server)["attendees"] == [%{"email" => payer.email}]

    assert {:ok, %{state: :full}} =
             BeginnersWorkshops.intake_page(token, clock: Fixtures.clock(@now))
  end

  for {operation, attrs} <- [
        {:defer, %{}},
        {:withdraw, %{refund: false}},
        {:withdraw, %{refund: true}},
        {:cancel_with_refund, %{}}
      ] do
    test "#{operation} #{inspect(attrs)} removes the credit-paid place after pause, even at event end",
         %{
           staff: staff,
           server: server
         } do
      person = stripe_paid_credit_holder!(staff)
      workshop = Fixtures.scheduled_fixture(staff)
      {intake, token} = contact!(staff, workshop, person)
      assert {:ok, %{outcome: :done}} = execute({:intake_link, token}, :confirm)
      assert :ok = sync(workshop.id)
      first = participant(server)
      assert first["attendees"] == [%{"email" => person.email}]
      count = length(HTTP.requests(server))
      assert :ok = WorkshopCalendar.pause()

      assert {:ok, _} =
               command(
                 staff,
                 {unquote(operation), workshop.id, intake.id, unquote(Macro.escape(attrs))}
               )

      assert :ok = sync(workshop.id)
      assert length(HTTP.requests(server)) == count
      assert :ok = WorkshopCalendar.resume()
      assert :ok = sync(workshop.id, @ends_at)
      assert participant(server)["id"] == first["id"]
      assert participant(server)["attendees"] == []
      assert List.last(HTTP.mutations(server)).query == "sendUpdates=all"

      assert {:error, :intake_closed} = execute({:intake_link, token}, :confirm)
      assert :ok = sync(workshop.id, @ends_at)
      assert participant(server)["attendees"] == []
    end
  end

  test "workshop cancellation carries the applied fee but cancels invitations independently", %{
    staff: staff,
    server: server
  } do
    person = holder!()
    workshop = Fixtures.scheduled_fixture(staff)
    {intake, token} = contact!(staff, workshop, person)
    assert {:ok, _} = execute({:intake_link, token}, :confirm)
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
    refute Jason.encode!(committee) =~ person.email
    refute Jason.encode!(HTTP.mutations(server)) =~ "PRIVATE"

    assert {:ok, %{state: "deferred", outcome: :already_done}} =
             command(staff, {:defer, workshop.id, intake.id, %{}})
  end

  test "a newly confirmed place after deferral receives a new entitlement, not the declined guest's RSVP",
       %{
         staff: staff,
         server: server
       } do
    person = holder!()
    workshop = Fixtures.scheduled_fixture(staff)
    {first_intake, token} = contact!(staff, workshop, person)
    assert {:ok, _} = execute({:intake_link, token}, :confirm)
    assert :ok = sync(workshop.id)
    first = participant(server)
    guest = %{"email" => person.email, "responseStatus" => "declined"}

    Agent.update(
      server,
      &%{&1 | events: Map.put(&1.events, first["id"], Map.put(first, "attendees", [guest]))}
    )

    assert :ok = WorkshopCalendar.pause()
    assert {:ok, _} = command(staff, {:defer, workshop.id, first_intake.id, %{}})
    {replacement, new_token} = contact!(staff, workshop, person)
    refute replacement.id == first_intake.id
    assert {:ok, _} = execute({:intake_link, new_token}, :confirm)
    assert :ok = WorkshopCalendar.resume()
    assert :ok = sync(workshop.id)
    assert participant(server)["id"] == first["id"]
    assert participant(server)["attendees"] == [%{"email" => person.email}]
    count = length(HTTP.mutations(server))
    assert {:error, :intake_closed} = execute({:intake_link, token}, :confirm)
    assert :ok = sync(workshop.id)
    assert length(HTTP.mutations(server)) == count
  end

  test "early finalisation spends or forfeits credit without removing invitations, including attendance corrections",
       %{
         staff: staff,
         server: server
       } do
    workshop = Fixtures.scheduled_fixture(staff)

    [attended, absent] =
      for _ <- 1..2 do
        {intake, token} = contact!(staff, workshop, holder!())
        assert {:ok, _} = execute({:intake_link, token}, :confirm)
        intake
      end

    assert :ok = sync(workshop.id)
    first = participant(server)
    count = length(HTTP.mutations(server))
    early = ~U[2026-11-14 19:00:00.000000Z]
    assert {:ok, _} = command(staff, {:check_in, workshop.id, attended.id}, early)

    assert {:ok, %{outcome: :finalised, attended: 1, no_show: 1}} =
             command(staff, {:finish_workshop, workshop.id}, early)

    assert :ok = sync(workshop.id, early)
    assert participant(server) == first

    for to <- ["attended", "no_show", "deferred"] do
      assert {:ok, _} =
               command(
                 staff,
                 {:correct_attendance, workshop.id, absent.id, %{to: to}},
                 ~U[2026-11-15 09:00:00.000000Z]
               )

      assert :ok = sync(workshop.id, ~U[2026-11-15 09:00:00.000000Z])
      assert participant(server) == first
    end

    assert length(HTTP.mutations(server)) == count
  end

  test "the exact end blocks delayed first invitations and missing-event recreation for credit confirmations",
       %{
         staff: staff,
         server: server
       } do
    workshop = Fixtures.scheduled_fixture(staff)
    {_intake, token} = contact!(staff, workshop, holder!())
    assert {:ok, _} = execute({:intake_link, token}, :confirm)
    assert :ok = sync(workshop.id, @ends_at)
    assert HTTP.mutations(server) == []
    assert :ok = sync(workshop.id, DateTime.add(@ends_at, -1))
    first = participant(server)
    assert [_] = first["attendees"]

    Agent.update(
      server,
      &%{&1 | events: %{first["id"] => %{"id" => first["id"], "status" => "cancelled"}}}
    )

    count = length(HTTP.mutations(server))
    assert :ok = sync(workshop.id, @ends_at)
    assert length(HTTP.mutations(server)) == count
  end

  test "bad credit recipients cannot block valid additions or a deferred guest's removal", %{
    staff: staff,
    server: server
  } do
    workshop = Fixtures.scheduled_fixture(staff)
    removed = holder!()
    {removed_intake, removed_token} = contact!(staff, workshop, removed)
    assert {:ok, _} = execute({:intake_link, removed_token}, :confirm)
    assert :ok = sync(workshop.id)

    rejected = holder!()
    valid = holder!()
    malformed = holder!()

    for person <- [rejected, valid, malformed] do
      {_intake, token} = contact!(staff, workshop, person)

      if person.id == malformed.id,
        do: person |> Ecto.Changeset.change(email: "not-an-address") |> Repo.update!()

      assert {:ok, _} = execute({:intake_link, token}, :confirm)
    end

    Agent.update(server, &%{&1 | rejected_recipients: [rejected.email]})
    assert {:ok, _} = command(staff, {:defer, workshop.id, removed_intake.id, %{}})
    assert :ok = sync(workshop.id)
    assert participant(server)["attendees"] == [%{"email" => valid.email}]
    assert {:ok, %{notifications: notifications}} = Dhc.Notifications.list_for_user(staff)
    assert Enum.count(notifications, &String.starts_with?(&1.body, "Calendar Invitation")) == 2
    count = length(HTTP.mutations(server))
    assert :ok = sync(workshop.id)
    assert length(HTTP.mutations(server)) == count
  end

  test "Google failure cannot undo a credit confirmation and uncertain retry does not invite twice",
       %{
         staff: staff,
         server: server
       } do
    workshop = Fixtures.scheduled_fixture(staff)
    {_intake, token} = contact!(staff, workshop, holder!())
    Agent.update(server, &%{&1 | status: 503})
    assert {:ok, %{outcome: :done}} = execute({:intake_link, token}, :confirm)
    assert {:snooze, 30} = sync(workshop.id)

    assert {:ok, %{state: :paid}} =
             BeginnersWorkshops.intake_page(token, clock: Fixtures.clock(@now))

    Agent.update(server, &%{&1 | status: nil, uncertain_update: true})
    assert {:snooze, 60} = sync(workshop.id, DateTime.add(@now, 30))
    assert :ok = sync(workshop.id, DateTime.add(@now, 90))
    assert [_] = participant(server)["attendees"]
    assert [_create, _add] = HTTP.mutations(server)
  end

  test "inactive confirmation retains its binding without sends, and resume cannot activate sending",
       %{
         staff: staff,
         server: server
       } do
    active_config = WorkshopCalendar.config()
    Application.put_env(:dhc, WorkshopCalendar, Keyword.put(active_config, :active, false))
    person = holder!()
    workshop = Fixtures.scheduled_fixture(staff)
    {_intake, token} = contact!(staff, workshop, person)
    assert {:ok, _} = execute({:intake_link, token}, :confirm)
    person |> Ecto.Changeset.change(email: "changed@example.com") |> Repo.update!()
    assert :ok = WorkshopCalendar.pause()
    assert :ok = WorkshopCalendar.resume()
    assert :ok = sync(workshop.id)
    assert HTTP.requests(server) == []

    # Only this isolated test installation is activated, never production.
    Application.put_env(:dhc, WorkshopCalendar, active_config)
    assert :ok = sync(workshop.id)
    assert participant(server)["attendees"] == [%{"email" => person.email}]
  end

  defp holder! do
    person = Fixtures.waiting_person_fixture(~U[2025-01-01 12:00:00Z])
    assert {:ok, %{outcome: :created}} = execute(:system, {:import_carried_fee, person.id, "Yes"})
    person
  end

  defp contact!(staff, workshop, person) do
    assert {:ok, %{id: id}} =
             command(staff, {:fast_track, workshop.id, {:waitlist_entry, person.id}})

    intake = Repo.get!(Intake, id)
    {intake, IntakeLink.token(id, intake.link_generation)}
  end

  defp command(staff, operation, now \\ @now),
    do: execute({:staff, staff}, operation, now)

  defp execute(actor, operation, now \\ @now),
    do: BeginnersWorkshops.execute(actor, operation, clock: Fixtures.clock(now))

  defp pay!(intake, token) do
    Stripe.stub_create()
    assert {:ok, _} = execute({:intake_link, token}, :start_payment)
    payment = Repo.get_by!(IntakePayment, intake_id: intake.id)

    session =
      Stripe.session(payment, %{
        "customer_email" => "payer@example.com",
        "customer_details" => %{"email" => "guardian@example.com", "name" => "PRIVATE"}
      })

    assert {:ok, %{outcome: :paid}} = execute(:stripe, {:complete_payment, session})

    payment
  end

  defp stripe_paid_credit_holder!(staff) do
    person = Fixtures.waiting_person_fixture(~U[2025-01-01 12:00:00Z])
    workshop = Fixtures.scheduled_fixture(staff)
    {intake, token} = contact!(staff, workshop, person)
    pay!(intake, token)
    assert {:ok, _} = command(staff, {:defer, workshop.id, intake.id, %{}})
    person
  end

  defp sync(id, now \\ @now),
    do:
      WorkshopCalendar.sync(:beginners_workshop, id, audience: :participant, clock: fn -> now end)

  defp participant(server),
    do: HTTP.events(server) |> Map.values() |> Enum.find(&Map.has_key?(&1, "attendees"))
end
