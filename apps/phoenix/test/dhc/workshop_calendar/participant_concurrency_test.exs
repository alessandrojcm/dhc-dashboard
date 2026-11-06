defmodule Dhc.WorkshopCalendar.ParticipantConcurrencyTest do
  use Dhc.DataCase, async: false

  import Ecto.Query
  import Dhc.ConcurrencyHelpers

  alias Dhc.Auth.Principal
  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Notifications.Notification
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.WorkshopCalendar
  alias Dhc.WorkshopCalendar.{Event, Google}
  alias Dhc.WorkshopCalendarHTTP
  alias Dhc.WorkshopFixtures
  alias Dhc.Workshops
  alias Dhc.Workshops.{PaymentAttempt, Refund, Registration, StripeStub, Workshop}

  @now ~U[2027-03-01 12:00:00Z]

  setup do
    previous = WorkshopCalendar.config()

    Application.put_env(:dhc, WorkshopCalendar,
      active: true,
      committee_calendar_id: "committee@test.invalid",
      participant_calendar_id: "participants@test.invalid",
      client_id: "participant-concurrency-client",
      client_secret: "participant-concurrency-secret",
      refresh_token: "participant-concurrency-refresh",
      req_options: [plug: {Req.Test, Google}]
    )

    restore_stripe = StripeStub.install()

    on_exit(fn ->
      restore_stripe.()
      Application.put_env(:dhc, WorkshopCalendar, previous)
    end)

    server = start_supervised!({Agent, fn -> WorkshopCalendarHTTP.initial() end})
    %{server: server}
  end

  test "duplicate participant workers never send concurrent attendee snapshots", %{server: server} do
    %{workshop: workshop} = ctx = committed_workshop!()
    _member = confirmed_member!(ctx, "first@example.com")
    parent = self()

    WorkshopCalendarHTTP.stub(server, fn conn ->
      if conn.host == "www.googleapis.com" and conn.method == "PUT" do
        send(parent, {:attendee_add_started, self()})

        receive do
          :continue_attendee_add -> :ok
        end
      end
    end)

    first = Task.async(fn -> outside_sandbox(fn -> sync(workshop.id) end) end)
    assert_receive {:attendee_add_started, google}, 5_000

    second = Task.async(fn -> outside_sandbox(fn -> sync(workshop.id) end) end)
    assert {:snooze, 5} = Task.await(second, 5_000)

    send(google, :continue_attendee_add)
    assert :ok = Task.await(first, 5_000)

    assert [event] = Map.values(WorkshopCalendarHTTP.events(server))
    assert event["attendees"] == [%{"email" => "first@example.com"}]
    assert [_insert, _add] = WorkshopCalendarHTTP.mutations(server)
  end

  test "a cancelled confirmed place wins over an in-flight attendee addition and removes it on retry",
       %{
         server: server
       } do
    %{workshop: workshop} = ctx = committed_workshop!()
    first = confirmed_member!(ctx, "kept@example.com")
    WorkshopCalendarHTTP.stub(server)
    outside_sandbox(fn -> assert :ok = sync(workshop.id) end)

    cancelled = confirmed_member!(ctx, "cancelled@example.com")
    parent = self()

    WorkshopCalendarHTTP.stub(server, fn conn ->
      if conn.host == "www.googleapis.com" and conn.method == "PUT" do
        send(parent, {:attendee_add_started, self()})

        receive do
          :continue_attendee_add -> :ok
        end
      end
    end)

    stale = Task.async(fn -> outside_sandbox(fn -> sync(workshop.id) end) end)
    assert_receive {:attendee_add_started, google}, 5_000

    outside_sandbox(fn ->
      assert {:ok, %{refund_pending: true}} =
               Workshops.cancel_member_registration(workshop.id, cancelled.principal_id)
    end)

    send(google, :continue_attendee_add)
    assert {:snooze, 1} = Task.await(stale, 5_000)

    WorkshopCalendarHTTP.stub(server)
    outside_sandbox(fn -> assert :ok = sync(workshop.id) end)

    assert [event] = Map.values(WorkshopCalendarHTTP.events(server))
    assert event["attendees"] == [%{"email" => "kept@example.com"}]
    assert %{status: "refunded"} = Repo.get!(Registration, cancelled.registration.id)
    assert %{status: "confirmed"} = Repo.get!(Registration, first.registration.id)
  end

  test "a provider RSVP edit fences roster replacement and survives the conditional retry", %{
    server: server
  } do
    %{workshop: workshop} = ctx = committed_workshop!()
    kept = confirmed_member!(ctx, "rsvp@example.com")
    removed = confirmed_member!(ctx, "removed@example.com")
    WorkshopCalendarHTTP.stub(server)
    outside_sandbox(fn -> assert :ok = sync(workshop.id) end)

    changed? = start_supervised!({Agent, fn -> false end}, id: {:rsvp_changed, workshop.id})

    WorkshopCalendarHTTP.stub(server, fn conn ->
      if conn.host == "www.googleapis.com" and conn.method == "PUT" and
           not Agent.get(changed?, & &1) do
        Agent.update(changed?, fn _ -> true end)

        Agent.update(server, fn state ->
          [event] = Map.values(state.events)

          attendees =
            Enum.map(event["attendees"], fn
              %{"email" => "rsvp@example.com"} = attendee ->
                Map.put(attendee, "responseStatus", "tentative")

              attendee ->
                attendee
            end)

          sequence = state.sequence + 1
          current = event |> Map.put("attendees", attendees) |> Map.put("etag", "\"#{sequence}\"")
          %{state | events: %{event["id"] => current}, sequence: sequence}
        end)
      end
    end)

    outside_sandbox(fn ->
      assert {:ok, %{refund_pending: true}} =
               Workshops.cancel_member_registration(workshop.id, removed.principal_id)
    end)

    outside_sandbox(fn -> assert {:snooze, 30} = sync(workshop.id) end)
    outside_sandbox(fn -> assert :ok = sync_at(workshop.id, DateTime.add(@now, 30)) end)

    assert [event] = Map.values(WorkshopCalendarHTTP.events(server))

    assert event["attendees"] == [
             %{"email" => "rsvp@example.com", "responseStatus" => "tentative"}
           ]

    assert %{status: "confirmed"} = Repo.get!(Registration, kept.registration.id)
  end

  test "a newly confirmed place during Google work fences the stale run and converges both attendees",
       %{
         server: server
       } do
    %{workshop: workshop} = ctx = committed_workshop!()
    first = confirmed_member!(ctx, "first-current@example.com")
    parent = self()

    WorkshopCalendarHTTP.stub(server, fn conn ->
      if conn.host == "www.googleapis.com" and conn.method == "PUT" do
        send(parent, {:first_attendee_add_started, self()})

        receive do
          :continue_first_attendee_add -> :ok
        end
      end
    end)

    stale = Task.async(fn -> outside_sandbox(fn -> sync(workshop.id) end) end)
    assert_receive {:first_attendee_add_started, google}, 5_000
    second = confirmed_member!(ctx, "second-current@example.com")

    send(google, :continue_first_attendee_add)
    assert {:snooze, 1} = Task.await(stale, 5_000)

    WorkshopCalendarHTTP.stub(server)
    outside_sandbox(fn -> assert :ok = sync(workshop.id) end)

    assert [event] = Map.values(WorkshopCalendarHTTP.events(server))

    assert event["attendees"] == [
             %{"email" => "first-current@example.com"},
             %{"email" => "second-current@example.com"}
           ]

    assert %{status: "confirmed"} = Repo.get!(Registration, first.registration.id)
    assert %{status: "confirmed"} = Repo.get!(Registration, second.registration.id)
  end

  defp confirmed_member!(ctx, email) do
    member = outside_sandbox(fn -> WorkshopFixtures.member_fixture(%{email: email}) end)

    outside_sandbox(fn ->
      {:ok, %{payment_intent_id: payment_intent_id}} =
        Workshops.create_member_payment_intent(ctx.workshop.id, member.principal_id, %{})

      StripeStub.put_object(
        :payment_intents,
        StripeStub.member_payment_intent(payment_intent_id, ctx.workshop.id, member.principal_id)
      )

      assert {:ok, %Registration{} = registration} =
               Workshops.complete_member_registration(
                 ctx.workshop.id,
                 member.principal_id,
                 payment_intent_id
               )

      Map.put(member, :registration, registration)
    end)
  end

  defp committed_workshop! do
    workshop =
      outside_sandbox(fn ->
        WorkshopFixtures.workshop_fixture(
          status: "published",
          start_date: ~U[2027-03-28 09:00:00Z],
          end_date: ~U[2027-03-28 11:00:00Z],
          max_capacity: 10,
          price_member: 1800.0
        )
      end)

    ctx = %{workshop: workshop}
    on_exit(fn -> outside_sandbox(fn -> cleanup!(ctx) end) end)
    ctx
  end

  defp cleanup!(ctx) do
    workshop_id = ctx.workshop.id

    Repo.delete_all(
      from(j in Oban.Job, where: fragment("?->>'source_id'", j.args) == ^workshop_id)
    )

    Repo.delete_all(
      from(e in Event, where: e.source_kind == "workshop" and e.source_id == ^workshop_id)
    )

    attempt_ids =
      Repo.all(
        from(pa in PaymentAttempt, where: pa.club_activity_id == ^workshop_id, select: pa.id)
      )

    registration_ids =
      Repo.all(from(r in Registration, where: r.club_activity_id == ^workshop_id, select: r.id))

    refund_ids =
      Repo.all(
        from(r in Refund,
          where: r.registration_id in ^registration_ids or r.payment_attempt_id in ^attempt_ids,
          select: r.id
        )
      )

    Repo.delete_all(
      from(j in Oban.Job, where: fragment("?->>'refund_id'", j.args) in ^refund_ids)
    )

    Repo.delete_all(from(r in Refund, where: r.id in ^refund_ids))

    principal_ids =
      Repo.all(
        from(r in Registration,
          where: r.club_activity_id == ^workshop_id and not is_nil(r.member_user_id),
          select: r.member_user_id
        )
      )

    Repo.delete_all(from(r in Registration, where: r.id in ^registration_ids))
    Repo.delete_all(from(pa in PaymentAttempt, where: pa.id in ^attempt_ids))
    Repo.delete_all(from(w in Workshop, where: w.id == ^workshop_id))

    Repo.delete_all(from(n in Notification, where: n.principal_id in ^principal_ids))
    Repo.delete_all(from(mp in MemberProfile, where: mp.id in ^principal_ids))
    Repo.delete_all(from(up in UserProfile, where: up.principal_id in ^principal_ids))
    Repo.delete_all(from(p in Principal, where: p.id in ^principal_ids))
  end

  defp sync(id),
    do: WorkshopCalendar.sync(:workshop, id, audience: :participant, clock: fn -> @now end)

  defp sync_at(id, now),
    do: WorkshopCalendar.sync(:workshop, id, audience: :participant, clock: fn -> now end)
end
