defmodule Dhc.WorkshopCalendar.ParticipantWorkshopsTest do
  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  import Dhc.WorkshopCalendarTestConfig, only: [activate!: 1, deactivate!: 0]

  alias Dhc.WorkshopCalendar
  alias Dhc.WorkshopCalendar.Google
  alias Dhc.WorkshopCalendar.Workers.SyncWorker
  alias Dhc.WorkshopCalendarHTTP
  alias Dhc.WorkshopFixtures
  alias Dhc.Workshops
  alias Dhc.Workshops.StripeStub
  alias Dhc.StripeHTTPStub

  @now ~U[2027-03-01 12:00:00Z]

  setup do
    previous = WorkshopCalendar.config()

    Application.put_env(:dhc, WorkshopCalendar,
      active: true,
      committee_calendar_id: "committee@test.invalid",
      participant_calendar_id: "participants@test.invalid",
      client_id: "calendar-client",
      client_secret: "calendar-secret",
      refresh_token: "calendar-refresh",
      req_options: [plug: {Req.Test, Google}]
    )

    on_exit(fn ->
      Application.put_env(:dhc, WorkshopCalendar, previous)
    end)

    server = start_supervised!({Agent, fn -> WorkshopCalendarHTTP.initial() end})
    WorkshopCalendarHTTP.stub(server)
    %{server: server}
  end

  test "a confirmed member place retains its confirmation email without leaking it to the committee source",
       %{server: server} do
    workshop =
      WorkshopFixtures.workshop_fixture(
        status: "published",
        price_member: 1800.0,
        start_date: ~U[2027-03-28 09:00:00Z],
        end_date: ~U[2027-03-28 11:00:00Z]
      )

    member = WorkshopFixtures.member_fixture(%{email: "member@example.com"})

    intent =
      StripeStub.member_payment_intent("pi_member", workshop.id, member.principal_id, %{
        "receipt_email" => "payer@example.com"
      })

    StripeHTTPStub.stub("GET", "/v1/payment_intents/pi_member", &StripeHTTPStub.json(&1, intent))

    assert {:ok, registration} =
             Workshops.complete_member_registration(workshop.id, member.principal_id, "pi_member")

    assert Workshops.calendar_place_ids(workshop.id) == [registration.id]
    assert registration.email == "member@example.com"

    assert_enqueued(
      worker: SyncWorker,
      args: %{source_kind: "workshop", source_id: workshop.id, audience: "participant"}
    )

    member.principal_id
    |> then(&Repo.get!(Dhc.Auth.Principal, &1))
    |> Ecto.Changeset.change(email: "changed@example.com")
    |> Repo.update!()

    assert {:ok, %{id: id}} =
             Workshops.complete_member_registration(workshop.id, member.principal_id, "pi_member")

    assert id == registration.id

    assert :ok =
             WorkshopCalendar.sync(:workshop, workshop.id,
               audience: :participant,
               clock: fn -> @now end
             )

    [participant_event] = Map.values(WorkshopCalendarHTTP.events(server))
    assert participant_event["attendees"] == [%{"email" => "member@example.com"}]
    assert participant_event["summary"] == "Test Workshop"
    assert participant_event["visibility"] == "private"
    assert participant_event["guestsCanSeeOtherGuests"] == false
    assert participant_event["guestsCanInviteOthers"] == false
    assert participant_event["guestsCanModify"] == false
    refute Map.has_key?(participant_event, "description")
    assert :ok = WorkshopCalendar.sync(:workshop, workshop.id, clock: fn -> @now end)

    assert [committee] =
             WorkshopCalendarHTTP.events(server)
             |> Map.values()
             |> Enum.reject(&Map.has_key?(&1, "attendees"))

    assert committee["id"] != participant_event["id"]
    refute Jason.encode!(committee) =~ "member@example.com"

    assert Enum.all?(
             all_enqueued(worker: SyncWorker),
             &(Map.keys(&1.args) -- ["source_kind", "source_id", "audience"] == [])
           )

    refute Map.has_key?(Workshops.calendar_projection(workshop.id), :email)
  end

  test "external confirmation and a repeated background job use the saved participant rather than unrelated payer metadata",
       %{server: server} do
    workshop = workshop!()
    attempt = Ecto.UUID.generate()

    session =
      StripeStub.checkout_session("cs_external", workshop.id, attempt, %{
        "customer_email" => "payer@example.com",
        "customer_details" => %{"email" => "guest@example.com", "name" => "Grace Hopper"}
      })

    StripeHTTPStub.stub(
      "GET",
      "/v1/checkout/sessions/cs_external",
      &StripeHTTPStub.json(&1, session)
    )

    StripeHTTPStub.stub(
      "POST",
      "/v1/payment_intents/pi_for_cs_external",
      &StripeHTTPStub.json(&1, %{"id" => "pi_for_cs_external"})
    )

    StripeHTTPStub.stub(
      "POST",
      "/v1/checkout/sessions",
      &StripeHTTPStub.json(&1, %{"id" => "cs_external", "client_secret" => "secret"})
    )

    assert {:ok, _} =
             Workshops.create_external_checkout_session(
               workshop.id,
               attempt,
               "http://localhost:5173/return?session_id={CHECKOUT_SESSION_ID}"
             )

    assert :ok = sync(workshop.id)
    assert WorkshopCalendarHTTP.mutations(server) == []

    assert {:ok, registration} =
             Workshops.complete_external_registration(workshop.id, "cs_external")

    assert {:ok, %{id: id}} = Workshops.complete_external_registration(workshop.id, "cs_external")
    assert id == registration.id
    args = %{"source_kind" => "workshop", "source_id" => workshop.id, "audience" => "participant"}
    assert :ok = perform_job(SyncWorker, args)
    count = length(WorkshopCalendarHTTP.mutations(server))
    assert :ok = perform_job(SyncWorker, args)
    assert length(WorkshopCalendarHTTP.mutations(server)) == count
    assert [%{"email" => "guest@example.com"}] = event(server)["attendees"]
  end

  test "pending checkout and compensating payments never receive an invitation", %{server: server} do
    workshop = workshop!()
    member = WorkshopFixtures.member_fixture()

    intent =
      StripeStub.member_payment_intent("pi_pending", workshop.id, member.principal_id, %{
        "status" => "processing"
      })

    StripeHTTPStub.stub("GET", "/v1/payment_intents/pi_pending", &StripeHTTPStub.json(&1, intent))

    assert {:error, :payment_not_completed} =
             Workshops.complete_member_registration(
               workshop.id,
               member.principal_id,
               "pi_pending"
             )

    assert :ok = sync(workshop.id)
    assert WorkshopCalendarHTTP.mutations(server) == []
    assert {:ok, _} = Workshops.cancel_workshop(workshop.id)
    intent = Map.put(intent, "status", "succeeded")
    StripeHTTPStub.stub("GET", "/v1/payment_intents/pi_pending", &StripeHTTPStub.json(&1, intent))

    assert {:error, :compensation_pending} =
             Workshops.complete_member_registration(
               workshop.id,
               member.principal_id,
               "pi_pending"
             )

    assert :ok = sync(workshop.id)
    assert WorkshopCalendarHTTP.mutations(server) == []
  end

  test "lost places are removed before refund progress and new places qualify despite an earlier Google decline",
       %{server: server} do
    workshop = workshop!()
    member = WorkshopFixtures.member_fixture()
    registration = confirm!(workshop, member)
    assert :ok = sync(workshop.id)
    first = event(server)

    Agent.update(server, fn state ->
      updated =
        Map.put(first, "attendees", [
          %{"email" => registration.email, "responseStatus" => "declined", "comment" => "Busy"}
        ])

      %{state | events: Map.put(state.events, first["id"], updated)}
    end)

    mutations = length(WorkshopCalendarHTTP.mutations(server))
    assert :ok = sync(workshop.id)
    assert length(WorkshopCalendarHTTP.mutations(server)) == mutations
    assert Workshops.calendar_place_ids(workshop.id) == [registration.id]

    assert {:ok, %{refund_pending: true}} =
             Workshops.cancel_member_registration(workshop.id, member.principal_id)

    assert :ok = sync(workshop.id)
    assert event(server)["attendees"] == []
    assert [%{status: "pending"}] = Repo.all(Dhc.Workshops.Refund)
    replacement = confirm!(workshop, member)
    refute replacement.id == registration.id
    assert :ok = sync(workshop.id)
    assert event(server)["id"] == first["id"]
    assert event(server)["attendees"] == [%{"email" => registration.email}]
    assert Enum.all?(WorkshopCalendarHTTP.mutations(server), &(&1.query == "sendUpdates=all"))
  end

  test "workshop cancellation cancels the private event after end while retaining committee history",
       %{server: server} do
    workshop = workshop!()
    confirm!(workshop, WorkshopFixtures.member_fixture())
    assert :ok = sync(workshop.id)
    first = event(server)
    assert :ok = WorkshopCalendar.sync(:workshop, workshop.id, clock: fn -> @now end)
    assert {:ok, _} = Workshops.cancel_workshop(workshop.id)
    assert :ok = sync(workshop.id, workshop.end_date)
    assert Map.fetch!(WorkshopCalendarHTTP.events(server), first["id"])["status"] == "cancelled"
    assert :ok = WorkshopCalendar.sync(:workshop, workshop.id, clock: fn -> workshop.end_date end)

    assert Enum.any?(
             Map.values(WorkshopCalendarHTTP.events(server)),
             &(&1["summary"] == "[Cancelled] Test Workshop" and &1["status"] == "confirmed")
           )
  end

  test "the exact end blocks first invitations and recreation but never an owed removal", %{
    server: server
  } do
    workshop = workshop!()
    member = WorkshopFixtures.member_fixture()
    confirm!(workshop, member)
    assert :ok = sync(workshop.id, workshop.end_date)
    assert WorkshopCalendarHTTP.mutations(server) == []
    assert :ok = sync(workshop.id)
    first = event(server)
    late = WorkshopFixtures.member_fixture()
    confirm!(workshop, late)
    assert :ok = sync(workshop.id, workshop.end_date)
    assert [_] = event(server)["attendees"]
    assert {:ok, _} = Workshops.cancel_member_registration(workshop.id, member.principal_id)
    assert :ok = sync(workshop.id, workshop.end_date)
    assert event(server)["attendees"] == []
    Agent.update(server, &%{&1 | events: %{}})
    count = length(WorkshopCalendarHTTP.mutations(server))
    assert :ok = sync(workshop.id, workshop.end_date)
    assert length(WorkshopCalendarHTTP.mutations(server)) == count
    refute first["id"] == nil
  end

  test "one Google-rejected address cannot block a valid invitation or another person's removal",
       %{server: server} do
    Sentry.Test.setup_sentry()
    workshop = workshop!()
    removed = WorkshopFixtures.member_fixture()
    confirm!(workshop, removed)
    assert :ok = sync(workshop.id)
    bad = WorkshopFixtures.member_fixture(%{email: "bad@example.com"})
    good = WorkshopFixtures.member_fixture(%{email: "good@example.com"})
    confirm!(workshop, bad)
    confirm!(workshop, good)
    Agent.update(server, &%{&1 | rejected_recipients: ["bad@example.com"]})
    assert {:ok, _} = Workshops.cancel_member_registration(workshop.id, removed.principal_id)
    assert :ok = sync(workshop.id)
    assert event(server)["attendees"] == [%{"email" => "good@example.com"}]

    assert [%Sentry.Event{}] = Sentry.Test.pop_sentry_reports()
    count = length(WorkshopCalendarHTTP.mutations(server))
    assert :ok = WorkshopCalendar.repair(clock: fn -> @now end)
    assert :ok = sync(workshop.id)
    assert length(WorkshopCalendarHTTP.mutations(server)) == count
    assert Sentry.Test.pop_sentry_reports() == []
  end

  test "an invalid saved participant address is per-place follow-up, never a payer fallback", %{
    server: server
  } do
    Sentry.Test.setup_sentry()
    workshop = workshop!()

    missing = WorkshopFixtures.member_fixture()

    Repo.update_all(from(p in Dhc.Auth.Principal, where: p.id == ^missing.principal_id),
      set: [email: "invalid-address"]
    )

    assert %{email: "invalid-address"} = confirm!(workshop, missing)
    good = WorkshopFixtures.member_fixture(%{email: "valid@example.com"})
    confirm!(workshop, good)
    assert :ok = sync(workshop.id)
    assert event(server)["attendees"] == [%{"email" => "valid@example.com"}]
    assert [%Sentry.Event{}] = Sentry.Test.pop_sentry_reports()
  end

  test "archival and attendance recording preserve the participant event without extra updates",
       %{server: server} do
    start = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.truncate(:second)
    finish = DateTime.add(start, 7200)

    workshop =
      WorkshopFixtures.workshop_fixture(
        status: "published",
        start_date: start,
        end_date: finish,
        price_member: 1800.0
      )

    member = WorkshopFixtures.member_fixture()
    registration = confirm!(workshop, member)
    assert :ok = sync(workshop.id, start)
    first = event(server)
    count = length(WorkshopCalendarHTTP.mutations(server))

    assert {:ok, _} =
             Workshops.update_workshop_attendance(workshop.id, member.principal_id, [
               %{
                 registration_id: registration.id,
                 attendance_status: "no_show",
                 notes: "PRIVATE note"
               }
             ])

    assert {:ok, :archived, _} = Workshops.delete_workshop(workshop.id)
    assert :ok = sync(workshop.id, finish)
    assert event(server) == first
    assert length(WorkshopCalendarHTTP.mutations(server)) == count
    refute Jason.encode!(first) =~ "PRIVATE"
  end

  test "a new confirmation after an unsynced cancellation is a fresh entitlement, not the old RSVP",
       %{server: server} do
    workshop = workshop!()
    member = WorkshopFixtures.member_fixture()
    registration = confirm!(workshop, member)
    assert :ok = sync(workshop.id)
    first = event(server)

    Agent.update(server, fn state ->
      declined =
        Map.put(first, "attendees", [
          %{"email" => registration.email, "responseStatus" => "declined"}
        ])

      %{state | events: Map.put(state.events, first["id"], declined)}
    end)

    assert {:ok, _} = Workshops.cancel_member_registration(workshop.id, member.principal_id)
    confirm!(workshop, member)
    assert :ok = sync(workshop.id)
    assert event(server)["attendees"] == [%{"email" => registration.email}]
    count = length(WorkshopCalendarHTTP.mutations(server))
    assert :ok = sync(workshop.id)
    assert length(WorkshopCalendarHTTP.mutations(server)) == count
  end

  test "inactive configuration retains confirmation and cancellation work until reconciliation uses current places",
       %{server: server} do
    workshop = workshop!()
    member = WorkshopFixtures.member_fixture()
    config = deactivate!()
    confirm!(workshop, member)
    assert {:ok, _} = Workshops.cancel_member_registration(workshop.id, member.principal_id)
    assert :ok = sync(workshop.id)
    assert WorkshopCalendarHTTP.requests(server) == []
    activate!(config)
    assert :ok = sync(workshop.id)
    assert WorkshopCalendarHTTP.mutations(server) == []
  end

  test "only confirmed registrations hold participant Calendar places, including after archival" do
    workshop = WorkshopFixtures.workshop_fixture(status: "published")
    confirmed_member = WorkshopFixtures.member_fixture()
    pending_member = WorkshopFixtures.member_fixture()

    confirmed =
      WorkshopFixtures.registration_fixture(%{
        workshop_id: workshop.id,
        member_user_id: confirmed_member.principal_id,
        status: "confirmed"
      })

    _pending =
      WorkshopFixtures.registration_fixture(%{
        workshop_id: workshop.id,
        member_user_id: pending_member.principal_id,
        status: "pending"
      })

    assert Workshops.calendar_place_ids(workshop.id) == [confirmed.id]

    assert {:ok, :archived, _summary} = Workshops.delete_workshop(workshop.id)
    assert Workshops.calendar_place_ids(workshop.id) == [confirmed.id]
  end

  test "an uncertain successful attendee update is read back without a duplicate invitation", %{
    server: server
  } do
    workshop = workshop!()
    member = WorkshopFixtures.member_fixture()
    confirm!(workshop, member)
    Agent.update(server, &Map.put(&1, :uncertain_update, true))
    assert {:snooze, 30} = sync(workshop.id)
    count = length(WorkshopCalendarHTTP.mutations(server))
    assert :ok = sync(workshop.id, DateTime.add(@now, 30))
    assert length(WorkshopCalendarHTTP.mutations(server)) == count
    assert [_] = event(server)["attendees"]
  end

  test "a paid external booking with only a payer fallback needs Calendar follow-up, not an invitation to the payer",
       %{server: server} do
    workshop = workshop!()

    registration =
      confirm_external!(workshop, nil, %{"customer_email" => "payer-only@example.com"})

    assert registration.status == "confirmed"
    assert registration.email == nil
    assert :ok = sync(workshop.id)
    assert WorkshopCalendarHTTP.mutations(server) == []
  end

  for lost <- [:member, :external] do
    test "losing the #{lost} place preserves the RSVP of another confirmed place at the same address",
         %{server: server} do
      workshop = workshop!()
      member = WorkshopFixtures.member_fixture(%{email: "shared@example.com"})
      confirm!(workshop, member)
      external = confirm_external!(workshop, "shared@example.com")
      assert :ok = sync(workshop.id)
      original = event(server)

      accepted =
        Map.put(original, "attendees", [
          %{"email" => "shared@example.com", "responseStatus" => "accepted"}
        ])

      Agent.update(server, &%{&1 | events: Map.put(&1.events, original["id"], accepted)})
      count = length(WorkshopCalendarHTTP.mutations(server))

      if unquote(lost) == :member do
        assert {:ok, _} = Workshops.cancel_member_registration(workshop.id, member.principal_id)
      else
        assert {:ok, _} =
                 Workshops.refund_registration(
                   workshop.id,
                   external.id,
                   "Cannot attend",
                   member.principal_id
                 )
      end

      assert :ok = sync(workshop.id)
      assert event(server)["attendees"] == accepted["attendees"]
      assert length(WorkshopCalendarHTTP.mutations(server)) == count
    end
  end

  defp confirm_external!(workshop, email, overrides \\ %{}) do
    attempt = Ecto.UUID.generate()
    session_id = "cs_#{attempt}"

    session =
      StripeStub.checkout_session(
        session_id,
        workshop.id,
        attempt,
        Map.merge(
          %{"customer_details" => %{"email" => email, "name" => "External Person"}},
          overrides
        )
      )

    StripeHTTPStub.stub(
      "GET",
      "/v1/checkout/sessions/#{session_id}",
      &StripeHTTPStub.json(&1, session)
    )

    StripeHTTPStub.stub(
      "POST",
      "/v1/payment_intents/pi_for_#{session_id}",
      &StripeHTTPStub.json(&1, %{"id" => "pi_for_#{session_id}"})
    )

    StripeHTTPStub.stub(
      "POST",
      "/v1/checkout/sessions",
      &StripeHTTPStub.json(&1, %{"id" => session_id, "client_secret" => "secret"})
    )

    assert {:ok, _} =
             Workshops.create_external_checkout_session(
               workshop.id,
               attempt,
               "http://localhost:5173/return?session_id={CHECKOUT_SESSION_ID}"
             )

    assert {:ok, registration} = Workshops.complete_external_registration(workshop.id, session_id)
    registration
  end

  defp workshop! do
    WorkshopFixtures.workshop_fixture(
      status: "published",
      is_public: true,
      price_member: 1800.0,
      price_non_member: 2400.0,
      start_date: ~U[2027-03-28 09:00:00Z],
      end_date: ~U[2027-03-28 11:00:00Z]
    )
  end

  defp confirm!(workshop, member) do
    id = "pi_#{Ecto.UUID.generate()}"
    intent = StripeStub.member_payment_intent(id, workshop.id, member.principal_id)
    StripeHTTPStub.stub("GET", "/v1/payment_intents/#{id}", &StripeHTTPStub.json(&1, intent))

    assert {:ok, registration} =
             Workshops.complete_member_registration(workshop.id, member.principal_id, id)

    registration
  end

  defp sync(id, now \\ @now),
    do: WorkshopCalendar.sync(:workshop, id, audience: :participant, clock: fn -> now end)

  defp event(server),
    do:
      server
      |> WorkshopCalendarHTTP.events()
      |> Map.values()
      |> Enum.find(&Map.has_key?(&1, "attendees"))
end
