defmodule Dhc.WorkshopCalendar.LaunchTest do
  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  import Ecto.Query

  alias Dhc.BeginnersWorkshopFixtures, as: BeginnersFixtures
  alias Dhc.Repo
  alias Dhc.WorkshopCalendar
  alias Dhc.WorkshopCalendar.{Control, Event, Recipient}
  alias Dhc.WorkshopCalendar.Google
  alias Dhc.WorkshopCalendarHTTP
  alias Dhc.WorkshopFixtures
  alias Dhc.Workshops

  @now ~U[2027-03-01 12:00:00Z]

  setup do
    previous = WorkshopCalendar.config()

    # Deliberately omit :active. Production sending is enabled by this durable
    # activation, never by a test-only configuration switch.
    Application.put_env(:dhc, WorkshopCalendar,
      environment: "isolated",
      committee_calendar_id: "launch-committee@test.invalid",
      participant_calendar_id: "launch-participants@test.invalid",
      client_id: "launch-client",
      client_secret: "launch-secret",
      refresh_token: "launch-refresh",
      req_options: [plug: {Req.Test, Google}]
    )

    on_exit(fn -> Application.put_env(:dhc, WorkshopCalendar, previous) end)
    server = start_supervised!({Agent, fn -> WorkshopCalendarHTTP.initial() end})
    WorkshopCalendarHTTP.stub(server)
    %{server: server}
  end

  test "preview is read-only and does not contact Google", %{server: server} do
    workshop = upcoming_workshop!()

    WorkshopFixtures.registration_fixture(%{
      workshop_id: workshop.id,
      external_user_id: WorkshopFixtures.external_user_fixture(%{email: "saved@example.test"}).id,
      status: "confirmed",
      email: "saved@example.test",
      confirmed_at: @now
    })

    before = calendar_rows()
    preview = WorkshopCalendar.preview(clock: fn -> @now end)

    assert preview.ready
    assert preview.active == false
    assert WorkshopCalendarHTTP.requests(server) == []
    assert calendar_rows() == before

    assert [
             %{participant: %{recipients: [%{recipient: "saved@example.test", action: :invite}]}}
           ] =
             Enum.filter(preview.workshops, &(&1.source_id == workshop.id))
  end

  test "activation is target-bound, durable, and captures a registration's saved address" do
    workshop = upcoming_workshop!()
    external = WorkshopFixtures.external_user_fixture(%{email: "before@example.test"})

    registration =
      WorkshopFixtures.registration_fixture(%{
        workshop_id: workshop.id,
        external_user_id: external.id,
        status: "confirmed",
        email: "saved-at-confirmation@example.test",
        confirmed_at: @now
      })

    assert {:error, :environment_mismatch} =
             WorkshopCalendar.activate("production", clock: fn -> @now end)

    assert {:ok, %{environment: "isolated", sources: 1}} =
             WorkshopCalendar.activate("isolated", clock: fn -> @now end)

    assert WorkshopCalendar.outbound?()

    Repo.update!(Ecto.Changeset.change(external, email: "edited-after-confirmation@example.test"))

    event = participant_event(workshop.id)

    recipient =
      Repo.one!(
        from(r in Recipient, where: r.event_id == ^event.id and r.place_id == ^registration.id)
      )

    assert recipient.recipient == "saved-at-confirmation@example.test"

    assert {:ok, _} = WorkshopCalendar.activate("isolated", clock: fn -> @now end)

    assert 1 ==
             Repo.aggregate(
               from(e in Event,
                 where: e.source_id == ^workshop.id and e.audience == "participant"
               ),
               :count
             )

    assert 1 ==
             Repo.aggregate(from(r in Recipient, where: r.place_id == ^registration.id), :count)
  end

  test "activation retains a Beginners' Workshop confirmed address after the waitlist email changes" do
    staff = BeginnersFixtures.staff_fixture()
    workshop = BeginnersFixtures.scheduled_fixture(staff, future_beginners_attrs())
    intake = BeginnersFixtures.paid_person_fixture!(workshop.id)

    assert {:ok, _} = WorkshopCalendar.activate("isolated", clock: fn -> @now end)
    recipient = Repo.one!(from(r in Recipient, where: r.place_id == ^intake.id))
    saved = recipient.recipient

    entry = Repo.get!(Dhc.Waitlist.WaitlistEntry, intake.waitlist_id)
    Repo.update!(Ecto.Changeset.change(entry, email: "edited-waitlist@example.test"))

    assert {:ok, _} = WorkshopCalendar.activate("isolated", clock: fn -> @now end)
    assert Repo.get!(Recipient, recipient.id).recipient == saved
  end

  test "activated historical Stripe and credit places create private Google events once", %{
    server: server
  } do
    regular = upcoming_workshop!()

    regular_registration =
      WorkshopFixtures.registration_fixture(%{
        workshop_id: regular.id,
        external_user_id: WorkshopFixtures.external_user_fixture().id,
        status: "confirmed",
        email: "historical-stripe@example.test",
        confirmed_at: @now
      })

    staff = BeginnersFixtures.staff_fixture()
    beginners = BeginnersFixtures.scheduled_fixture(staff, future_beginners_attrs())
    stripe_intake = BeginnersFixtures.paid_person_fixture!(beginners.id)
    credit_person = BeginnersFixtures.waiting_person_fixture(@now)
    {credit_intake, _token} = BeginnersFixtures.intake_fixture!(beginners.id, credit_person)
    credit_intake = BeginnersFixtures.force_carried_fee_paid!(credit_intake)

    assert {:ok, _} = WorkshopCalendar.activate("isolated", clock: fn -> @now end)

    for {kind, id} <- [workshop: regular.id, beginners_workshop: beginners.id] do
      assert :ok = WorkshopCalendar.sync(kind, id, clock: fn -> @now end)
      assert :ok = WorkshopCalendar.sync(kind, id, audience: :participant, clock: fn -> @now end)
    end

    events = Map.values(WorkshopCalendarHTTP.events(server))
    assert [_, _, _, _] = events

    assert Enum.any?(events, fn event ->
             event["summary"] == "Test Workshop" and
               event["attendees"] == [%{"email" => regular_registration.email}]
           end)

    assert Enum.any?(events, fn event ->
             event["summary"] == "Beginners' Workshop" and
               Enum.sort(Map.get(event, "attendees", [])) ==
                 Enum.sort([
                   %{"email" => waitlist_email(stripe_intake)},
                   %{"email" => waitlist_email(credit_intake)}
                 ])
           end)

    mutations = length(WorkshopCalendarHTTP.mutations(server))
    assert {:ok, _} = WorkshopCalendar.activate("isolated", clock: fn -> @now end)

    for {kind, id} <- [workshop: regular.id, beginners_workshop: beginners.id] do
      assert :ok = WorkshopCalendar.sync(kind, id, clock: fn -> @now end)
      assert :ok = WorkshopCalendar.sync(kind, id, audience: :participant, clock: fn -> @now end)
    end

    assert length(WorkshopCalendarHTTP.mutations(server)) == mutations
  end

  test "malformed and missing saved recipients follow up without a payer fallback or blocking valid guests",
       %{
         server: server
       } do
    Sentry.Test.setup_sentry()
    workshop = upcoming_workshop!()

    WorkshopFixtures.registration_fixture(%{
      workshop_id: workshop.id,
      external_user_id: WorkshopFixtures.external_user_fixture().id,
      status: "confirmed",
      email: "not-an-email",
      confirmed_at: @now
    })

    WorkshopFixtures.registration_fixture(%{
      workshop_id: workshop.id,
      external_user_id: WorkshopFixtures.external_user_fixture().id,
      status: "confirmed",
      email: "valid@example.test",
      confirmed_at: @now
    })

    missing =
      WorkshopFixtures.registration_fixture(%{
        workshop_id: workshop.id,
        external_user_id:
          WorkshopFixtures.external_user_fixture(%{email: "payer@example.test"}).id,
        status: "confirmed",
        email: nil,
        confirmed_at: @now
      })

    preview = WorkshopCalendar.preview(clock: fn -> @now end)
    row = Enum.find(preview.workshops, &(&1.source_id == workshop.id))
    assert Enum.any?(row.participant.recipients, &(&1.issue == :invalid_recipient))
    assert Enum.any?(row.participant.recipients, &(&1.issue == :missing_recipient))

    assert {:ok, %{sources: 1}} = WorkshopCalendar.activate("isolated", clock: fn -> @now end)

    assert :ok =
             WorkshopCalendar.sync(:workshop, workshop.id,
               audience: :participant,
               clock: fn -> @now end
             )

    assert Enum.any?(Map.values(WorkshopCalendarHTTP.events(server)), fn event ->
             event["attendees"] == [%{"email" => "valid@example.test"}]
           end)

    assert [_, _] = Sentry.Test.pop_sentry_reports()
    refute Repo.get_by!(Recipient, place_id: missing.id).recipient == "payer@example.test"
  end

  test "a changed target configuration disables durable sending, while an unchanged redeploy preserves it" do
    assert {:ok, _} = WorkshopCalendar.activate("isolated", clock: fn -> @now end)
    deployed = WorkshopCalendar.config()
    assert WorkshopCalendar.outbound?()

    Application.put_env(
      :dhc,
      WorkshopCalendar,
      Keyword.put(deployed, :participant_calendar_id, "different-participants@test.invalid")
    )

    refute WorkshopCalendar.outbound?()
    Application.put_env(:dhc, WorkshopCalendar, deployed)
    assert WorkshopCalendar.outbound?()
  end

  test "schedule blockers prevent every activation write, and cancelled or past sources are excluded" do
    valid = upcoming_workshop!()
    staff = BeginnersFixtures.staff_fixture()
    blocker = BeginnersFixtures.scheduled_fixture(staff, future_beginners_attrs())

    Repo.update!(
      Ecto.Changeset.change(
        Repo.get!(Dhc.BeginnersWorkshops.BeginnersWorkshop, blocker.id),
        end_time: nil
      )
    )

    cancelled = upcoming_workshop!()
    assert {:ok, _} = Workshops.publish_workshop(cancelled.id)
    assert {:ok, _} = Workshops.cancel_workshop(cancelled.id)

    _past =
      WorkshopFixtures.workshop_fixture(%{
        start_date: DateTime.add(@now, -7200),
        end_date: DateTime.add(@now, -3600)
      })

    preview = WorkshopCalendar.preview(clock: fn -> @now end)

    blocker_id = blocker.id

    assert %{source_id: ^blocker_id, issue: :missing_end_time} =
             Enum.find(preview.workshops, &(&1.source_id == blocker.id))

    assert Enum.all?(preview.blockers, &(&1.source_id == blocker.id))

    events_before_activation = Repo.aggregate(Event, :count)

    assert {:error, {:invalid_schedules, _}} =
             WorkshopCalendar.activate("isolated", clock: fn -> @now end)

    assert Repo.get(Control, 1).activation_key == nil
    assert Repo.aggregate(Event, :count) == events_before_activation
    assert Enum.any?(preview.workshops, &(&1.source_id == valid.id))
    refute Enum.any?(preview.workshops, &(&1.source_id == cancelled.id))
  end

  test "a cancellation after preview is re-read and never published or invited", %{server: server} do
    workshop = upcoming_workshop!()

    registration =
      WorkshopFixtures.registration_fixture(%{
        workshop_id: workshop.id,
        external_user_id: WorkshopFixtures.external_user_fixture().id,
        status: "confirmed",
        email: "will-not-be-invited@example.test",
        confirmed_at: @now
      })

    assert %{ready: true} = WorkshopCalendar.preview(clock: fn -> @now end)
    assert {:ok, _} = Workshops.publish_workshop(workshop.id)
    assert {:ok, _} = Workshops.cancel_workshop(workshop.id)
    assert {:ok, %{sources: 0}} = WorkshopCalendar.activate("isolated", clock: fn -> @now end)
    refute Repo.exists?(from(r in Recipient, where: r.place_id == ^registration.id))

    assert :ok = WorkshopCalendar.sync(:workshop, workshop.id, clock: fn -> @now end)

    assert :ok =
             WorkshopCalendar.sync(:workshop, workshop.id,
               audience: :participant,
               clock: fn -> @now end
             )

    assert WorkshopCalendarHTTP.mutations(server) == []
  end

  defp upcoming_workshop! do
    WorkshopFixtures.workshop_fixture(%{
      start_date: DateTime.add(@now, 86_400),
      end_date: DateTime.add(@now, 93_600)
    })
  end

  defp future_beginners_attrs do
    %{
      "date" => "2027-03-28",
      "start_time" => "10:00",
      "end_time" => "12:00",
      "venue" => "Launch hall"
    }
  end

  defp participant_event(source_id),
    do:
      Repo.one!(
        from(e in Event, where: e.source_id == ^source_id and e.audience == "participant")
      )

  defp waitlist_email(intake),
    do: Repo.get!(Dhc.Waitlist.WaitlistEntry, intake.waitlist_id).email

  defp calendar_rows,
    do:
      {Repo.all(Event), Repo.all(Recipient), Repo.get(Control, 1),
       Repo.aggregate(Oban.Job, :count)}
end
