defmodule Dhc.WorkshopCalendar.BeginnersParticipantConcurrencyTest do
  @moduledoc """
  ALE-434 participant-calendar races use independent database connections.

  The lock barriers make the source command order and the Google request
  boundary observable without timing sleeps.
  """

  use Dhc.DataCase, async: false

  import Ecto.Query
  import Dhc.BeginnersWorkshopFixtures
  import Dhc.ConcurrencyHelpers

  alias Dhc.Auth.{Principal, UserRole}
  alias Dhc.BeginnersIntakeStripe, as: Stripe
  alias Dhc.BeginnersWorkshops

  alias Dhc.BeginnersWorkshops.{
    Batch,
    BeginnersWorkshop,
    CarriedFee,
    Clock,
    Intake,
    IntakeEmailLog,
    IntakeEvent,
    IntakePayment,
    IntakeRefund
  }

  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Notifications.Notification
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Waitlist.WaitlistEntry
  alias Dhc.WorkshopCalendar
  alias Dhc.WorkshopCalendar.{Event, Google}
  alias Dhc.WorkshopCalendarHTTP

  @now ~U[2026-10-22 12:00:00.000000Z]
  @workshop_lock "SELECT id FROM beginners_workshops WHERE id = $1 FOR UPDATE"

  setup do
    previous = WorkshopCalendar.config()

    Application.put_env(:dhc, WorkshopCalendar,
      active: true,
      committee_calendar_id: "committee@test.invalid",
      participant_calendar_id: "participants@test.invalid",
      client_id: "beginners-participant-concurrency-client",
      client_secret: "beginners-participant-concurrency-secret",
      refresh_token: "beginners-participant-concurrency-refresh",
      req_options: [plug: {Req.Test, Google}]
    )

    on_exit(fn -> Application.put_env(:dhc, WorkshopCalendar, previous) end)
    server = start_supervised!({Agent, fn -> WorkshopCalendarHTTP.initial() end})
    %{server: server}
  end

  test "completion before withdrawal records then removes the historical place", %{server: server} do
    committed_paid_checkout!(fn ctx ->
      {complete, withdraw} = complete_then!(ctx, fn -> withdraw(ctx) end)

      assert {:ok, %{outcome: :paid}} = Task.await(complete, :infinity)
      assert {:ok, %{state: "withdrawn", outcome: :done}} = Task.await(withdraw, :infinity)

      assert calendar_place_ids(ctx.workshop.id) == [ctx.intake.id]
      WorkshopCalendarHTTP.stub(server)
      outside_sandbox(fn -> assert :ok = sync(ctx.workshop.id) end)
      assert WorkshopCalendarHTTP.events(server) == %{}
    end)
  end

  test "completion before workshop cancellation never restores the cancelled place", %{
    server: server
  } do
    committed_paid_checkout!(fn ctx ->
      {complete, cancel} = complete_then!(ctx, fn -> cancel_workshop(ctx) end)

      assert {:ok, %{outcome: :paid}} = Task.await(complete, :infinity)
      assert {:ok, _} = Task.await(cancel, :infinity)

      assert calendar_place_ids(ctx.workshop.id) == [ctx.intake.id]
      WorkshopCalendarHTTP.stub(server)
      outside_sandbox(fn -> assert :ok = sync(ctx.workshop.id) end)
      assert WorkshopCalendarHTTP.events(server) == %{}
    end)
  end

  test "withdrawal before completion removes the late Stripe-confirmed place", %{server: server} do
    committed_paid_checkout!(fn ctx ->
      {withdraw, complete} = action_then_complete!(ctx, fn -> withdraw(ctx) end)

      assert {:ok, %{state: "declined", outcome: :done}} = Task.await(withdraw, :infinity)
      assert {:ok, %{outcome: :paid_after_close}} = Task.await(complete, :infinity)

      assert calendar_place_ids(ctx.workshop.id) == []
      WorkshopCalendarHTTP.stub(server)
      outside_sandbox(fn -> assert :ok = sync(ctx.workshop.id) end)
      assert WorkshopCalendarHTTP.events(server) == %{}
    end)
  end

  test "workshop cancellation before completion removes the late Stripe-confirmed place", %{
    server: server
  } do
    committed_paid_checkout!(fn ctx ->
      {cancel, complete} = action_then_complete!(ctx, fn -> cancel_workshop(ctx) end)

      assert {:ok, _} = Task.await(cancel, :infinity)
      assert {:ok, %{outcome: :paid_after_close}} = Task.await(complete, :infinity)

      assert calendar_place_ids(ctx.workshop.id) == []
      WorkshopCalendarHTTP.stub(server)
      outside_sandbox(fn -> assert :ok = sync(ctx.workshop.id) end)
      assert WorkshopCalendarHTTP.events(server) == %{}
    end)
  end

  test "withdrawal fences an in-flight attendee addition and retry keeps only the live attendee",
       %{
         server: server
       } do
    committed_paid_people!(
      2,
      fn ctx ->
        [kept, _removed_person] = ctx.people
        removed = Enum.at(ctx.intakes, 1)
        WorkshopCalendarHTTP.stub(server)
        outside_sandbox(fn -> assert :ok = sync(ctx.workshop.id) end)

        outside_sandbox(fn -> assert {:ok, %{outcome: :paid}} = complete(second_payment(ctx)) end)

        parent = self()

        WorkshopCalendarHTTP.stub(server, fn conn ->
          if conn.host == "www.googleapis.com" and conn.method == "PUT" do
            send(parent, {:attendee_add_started, self()})
            receive do: (:continue_attendee_add -> :ok)
          end
        end)

        stale = Task.async(fn -> outside_sandbox(fn -> sync(ctx.workshop.id) end) end)
        assert_receive {:attendee_add_started, google}, 5_000

        outside_sandbox(fn -> assert {:ok, %{state: "withdrawn"}} = withdraw(ctx, removed) end)
        send(google, :continue_attendee_add)
        assert {:snooze, 1} = Task.await(stale, 5_000)

        WorkshopCalendarHTTP.stub(server)
        outside_sandbox(fn -> assert :ok = sync(ctx.workshop.id) end)

        assert [event] = Map.values(WorkshopCalendarHTTP.events(server))
        assert event["attendees"] == [%{"email" => kept.email}]
      end,
      complete_count: 1
    )
  end

  test "workshop cancellation fences an in-flight attendee addition and leaves its cancelled tombstone",
       %{
         server: server
       } do
    committed_paid_people!(
      2,
      fn ctx ->
        WorkshopCalendarHTTP.stub(server)
        outside_sandbox(fn -> assert :ok = sync(ctx.workshop.id) end)
        outside_sandbox(fn -> assert {:ok, %{outcome: :paid}} = complete(second_payment(ctx)) end)
        parent = self()

        WorkshopCalendarHTTP.stub(server, fn conn ->
          if conn.host == "www.googleapis.com" and conn.method == "PUT" do
            send(parent, {:attendee_add_started, self()})
            receive do: (:continue_attendee_add -> :ok)
          end
        end)

        stale = Task.async(fn -> outside_sandbox(fn -> sync(ctx.workshop.id) end) end)
        assert_receive {:attendee_add_started, google}, 5_000

        outside_sandbox(fn -> assert {:ok, _} = cancel_workshop(ctx) end)
        send(google, :continue_attendee_add)
        assert {:snooze, 1} = Task.await(stale, 5_000)

        WorkshopCalendarHTTP.stub(server)
        outside_sandbox(fn -> assert :ok = sync(ctx.workshop.id) end)
        assert [event] = Map.values(WorkshopCalendarHTTP.events(server))
        assert event["status"] == "cancelled"
      end,
      complete_count: 1
    )
  end

  test "a newer reschedule fences an in-flight schedule update and preserves the RSVP", %{
    server: server
  } do
    committed_paid_people!(1, fn ctx ->
      [person] = ctx.people
      WorkshopCalendarHTTP.stub(server)
      outside_sandbox(fn -> assert :ok = sync(ctx.workshop.id) end)
      [created] = Map.values(WorkshopCalendarHTTP.events(server))

      accepted = %{"email" => person.email, "responseStatus" => "accepted"}

      Agent.update(server, fn state ->
        event = Map.put(created, "attendees", [accepted])
        %{state | events: Map.put(state.events, event["id"], event)}
      end)

      outside_sandbox(fn -> assert {:ok, _} = reschedule(ctx, first_schedule()) end)
      parent = self()

      WorkshopCalendarHTTP.stub(server, fn conn ->
        if conn.host == "www.googleapis.com" and conn.method == "PUT" do
          send(parent, {:schedule_update_started, self()})
          receive do: (:continue_schedule_update -> :ok)
        end
      end)

      stale = Task.async(fn -> outside_sandbox(fn -> sync(ctx.workshop.id) end) end)
      assert_receive {:schedule_update_started, google}, 5_000
      outside_sandbox(fn -> assert {:ok, _} = reschedule(ctx, current_schedule()) end)
      send(google, :continue_schedule_update)
      assert {:snooze, 1} = Task.await(stale, 5_000)

      WorkshopCalendarHTTP.stub(server)
      outside_sandbox(fn -> assert :ok = sync(ctx.workshop.id) end)

      assert [event] = Map.values(WorkshopCalendarHTTP.events(server))
      assert event["attendees"] == [accepted]
      assert event["start"]["dateTime"] == "2026-12-12T12:00:00Z"
      assert event["end"]["dateTime"] == "2026-12-12T14:00:00Z"
      assert event["location"] == "Current hall"
    end)
  end

  test "held-credit confirmations race for the last place and only the winner reaches Calendar",
       %{
         server: server
       } do
    for _attempt <- 1..3 do
      Agent.update(server, fn _state -> WorkshopCalendarHTTP.initial() end)

      committed_credit_people!(
        2,
        fn ctx ->
          results =
            hold_lock_then(
              @workshop_lock,
              [dump(ctx.workshop.id)],
              [
                fn -> {:first, confirm_by_person(ctx, 0)} end,
                fn -> {:second, confirm_by_person(ctx, 1)} end
              ]
            )

          assert [{winner, {:ok, %{outcome: :done}}}] =
                   Enum.filter(results, fn {_person, result} ->
                     match?({:ok, %{outcome: :done}}, result)
                   end)

          assert Enum.count(results, fn {_person, result} -> result == {:error, :full} end) == 1

          winner_index = if winner == :first, do: 0, else: 1
          winner_intake = Enum.at(ctx.intakes, winner_index)
          winner_person = Enum.at(ctx.people, winner_index)

          assert calendar_place_ids(ctx.workshop.id) == [winner_intake.id]

          WorkshopCalendarHTTP.stub(server)
          outside_sandbox(fn -> assert :ok = sync(ctx.workshop.id) end)

          assert [event] = Map.values(WorkshopCalendarHTTP.events(server))
          assert event["attendees"] == [%{"email" => winner_person.email}]
        end,
        capacity: 1
      )
    end
  end

  test "person and staff confirmations converge on one credit entitlement and one Calendar guest",
       %{
         server: server
       } do
    committed_credit_people!(
      1,
      fn ctx ->
        results =
          hold_lock_then(
            @workshop_lock,
            [dump(ctx.workshop.id)],
            [
              fn -> {:person, confirm_by_person(ctx, 0)} end,
              fn -> {:staff, confirm_by_staff(ctx, 0)} end
            ]
          )

        assert Enum.count(results, fn {_actor, result} ->
                 match?({:ok, %{outcome: :done}}, result)
               end) == 1

        assert Enum.count(results, fn {_actor, result} ->
                 match?({:ok, %{outcome: :already_done}}, result)
               end) == 1

        [intake] = ctx.intakes
        [person] = ctx.people
        assert calendar_place_ids(ctx.workshop.id) == [intake.id]

        WorkshopCalendarHTTP.stub(server)
        outside_sandbox(fn -> assert :ok = sync(ctx.workshop.id) end)

        assert [event] = Map.values(WorkshopCalendarHTTP.events(server))
        assert event["attendees"] == [%{"email" => person.email}]
      end,
      capacity: 1
    )
  end

  test "withdrawal fences an in-flight Calendar addition for a confirmed credit", %{
    server: server
  } do
    committed_credit_people!(
      2,
      fn ctx ->
        WorkshopCalendarHTTP.stub(server)
        outside_sandbox(fn -> assert {:ok, %{outcome: :done}} = confirm_by_person(ctx, 0) end)
        outside_sandbox(fn -> assert :ok = sync(ctx.workshop.id) end)
        outside_sandbox(fn -> assert {:ok, %{outcome: :done}} = confirm_by_person(ctx, 1) end)
        parent = self()

        WorkshopCalendarHTTP.stub(server, fn conn ->
          if conn.host == "www.googleapis.com" and conn.method == "PUT" do
            send(parent, {:attendee_add_started, self()})

            receive do
              :continue_attendee_add -> :ok
            end
          end
        end)

        stale = Task.async(fn -> outside_sandbox(fn -> sync(ctx.workshop.id) end) end)
        assert_receive {:attendee_add_started, google}, 5_000

        outside_sandbox(fn ->
          assert {:ok, %{state: "withdrawn", outcome: :done}} =
                   withdraw(ctx, Enum.at(ctx.intakes, 1))
        end)

        send(google, :continue_attendee_add)
        assert {:snooze, 1} = Task.await(stale, 5_000)

        WorkshopCalendarHTTP.stub(server)
        outside_sandbox(fn -> assert :ok = sync(ctx.workshop.id) end)
        assert [event] = Map.values(WorkshopCalendarHTTP.events(server))
        assert event["attendees"] == [%{"email" => Enum.at(ctx.people, 0).email}]
      end,
      capacity: 2
    )
  end

  defp complete_then!(ctx, after_complete) do
    with_held_workshop_lock!(ctx, &start_completion_then(&1, ctx, after_complete))
  end

  defp action_then_complete!(ctx, action) do
    with_held_workshop_lock!(ctx, &start_action_then_completion(&1, ctx, action))
  end

  defp start_completion_then(_, ctx, after_complete) do
    complete = async_complete(ctx)
    :ok = wait_for_lock_waiters(1)
    following = async_outside(after_complete)
    :ok = wait_for_lock_waiters(2)
    {complete, following}
  end

  defp start_action_then_completion(_, ctx, action) do
    first = async_outside(action)
    :ok = wait_for_lock_waiters(1)
    complete = async_complete(ctx)
    :ok = wait_for_lock_waiters(2)
    {first, complete}
  end

  defp with_held_workshop_lock!(ctx, fun) do
    parent = self()
    holder = Task.async(fn -> hold_row_lock(@workshop_lock, [dump(ctx.workshop.id)], parent) end)
    assert_receive :locked, 5_000

    try do
      fun.(ctx)
    after
      send(holder.pid, :release)
      assert {:ok, _} = Task.await(holder, 5_000)
    end
  end

  defp async_complete(ctx), do: Task.async(fn -> complete_outside_sandbox(ctx) end)

  defp complete_outside_sandbox(ctx), do: outside_sandbox(fn -> complete(ctx) end)

  defp async_outside(fun), do: Task.async(fn -> outside_sandbox(fun) end)

  defp committed_paid_checkout!(fun) do
    committed_paid_people!(
      1,
      fn %{payments: [payment]} = ctx ->
        fun.(Map.put(ctx, :session, Stripe.session(payment)))
      end,
      complete_count: 0
    )
  end

  # Credit confirmation must run through the same import and command seams as
  # production. In particular, do not manufacture a paid Intake: confirmation
  # owns the seat, confirmation history and Calendar participant intent.
  defp committed_credit_people!(count, fun, opts) do
    ctx = outside_sandbox(fn -> build_credit_people_context!(count, opts) end)

    on_exit(fn -> outside_sandbox(fn -> cleanup!(ctx) end) end)
    fun.(ctx)
  end

  defp build_credit_people_context!(count, opts) do
    staff = staff_fixture("beginners_coordinator")
    capacity = Keyword.get(opts, :capacity, count)
    workshop = scheduled_fixture(staff, %{"capacity" => capacity})
    people = waiting_people_fixture(count)
    intake_tokens = Enum.map(people, &intake_fixture!(workshop.id, &1, @now))
    intakes = Enum.map(intake_tokens, &elem(&1, 0))

    Enum.each(people, fn person ->
      assert {:ok, %{outcome: :created}} =
               execute(:system, {:import_carried_fee, person.id, "Paid before migration"})
    end)

    %{
      workshop: workshop,
      staff: staff,
      intakes: intakes,
      intake: hd(intakes),
      people: people,
      tokens: Map.new(intake_tokens, fn {intake, token} -> {intake.id, token} end),
      payments: []
    }
  end

  defp committed_paid_people!(count, fun, opts \\ []) do
    ctx = outside_sandbox(fn -> build_paid_people_context!(count, opts) end)

    on_exit(fn -> outside_sandbox(fn -> cleanup!(ctx) end) end)
    fun.(ctx)
  end

  defp build_paid_people_context!(count, opts) do
    staff = staff_fixture("beginners_coordinator")
    {workshop, intake_tokens} = contacted_fixture(staff, count)
    payments = start_payments!(intake_tokens)
    complete_payments!(payments, Keyword.get(opts, :complete_count, count))
    build_context(workshop, staff, intake_tokens, payments)
  end

  defp start_payments!(intake_tokens) do
    Stripe.stub_create()

    for {intake, token} <- intake_tokens do
      assert {:ok, _} = execute({:intake_link, token}, :start_payment)
      Repo.one!(from(p in IntakePayment, where: p.intake_id == ^intake.id))
    end
  end

  defp complete_payments!(payments, count) do
    payments
    |> Enum.take(count)
    |> Enum.each(&complete_payment!/1)
  end

  defp complete_payment!(payment) do
    assert {:ok, %{outcome: :paid}} = complete(%{session: Stripe.session(payment)})
  end

  defp build_context(workshop, staff, intake_tokens, payments) do
    intakes = Enum.map(intake_tokens, &elem(&1, 0))

    %{
      workshop: workshop,
      staff: staff,
      intakes: intakes,
      intake: hd(intakes),
      people: people_for_intakes!(intakes),
      payments: payments,
      session: Stripe.session(hd(payments))
    }
  end

  defp people_for_intakes!(intakes) do
    people_by_id =
      Repo.all(from(w in WaitlistEntry, where: w.id in ^Enum.map(intakes, & &1.waitlist_id)))
      |> Map.new(&{&1.id, &1})

    Enum.map(intakes, &Map.fetch!(people_by_id, &1.waitlist_id))
  end

  defp execute(actor, command),
    do: BeginnersWorkshops.execute(actor, command, clock: Clock.fixed(@now))

  defp complete(%{session: session}), do: execute(:stripe, {:complete_payment, session})

  defp confirm_by_person(ctx, index) do
    intake = Enum.at(ctx.intakes, index)
    execute({:intake_link, Map.fetch!(ctx.tokens, intake.id)}, :confirm)
  end

  defp confirm_by_staff(ctx, index) do
    intake = Enum.at(ctx.intakes, index)
    execute({:staff, ctx.staff}, {:confirm, ctx.workshop.id, intake.id, %{}})
  end

  defp calendar_place_ids(workshop_id),
    do: outside_sandbox(fn -> BeginnersWorkshops.calendar_place_ids(workshop_id) end)

  defp second_payment(ctx),
    do: ctx.payments |> Enum.at(1) |> Stripe.session() |> then(&%{session: &1})

  defp withdraw(ctx, intake \\ nil) do
    intake = intake || ctx.intake
    execute({:staff, ctx.staff}, {:withdraw, ctx.workshop.id, intake.id, %{"refund" => false}})
  end

  defp cancel_workshop(ctx),
    do: execute({:staff, ctx.staff}, {:cancel_workshop, ctx.workshop.id, %{}})

  defp reschedule(ctx, attrs),
    do: execute({:staff, ctx.staff}, {:reschedule_workshop, ctx.workshop.id, attrs})

  defp sync(id),
    do:
      WorkshopCalendar.sync(:beginners_workshop, id,
        audience: :participant,
        clock: fn -> @now end
      )

  defp first_schedule,
    do: %{
      "date" => "2026-12-05",
      "start_time" => "10:00",
      "end_time" => "12:00",
      "venue" => "First hall"
    }

  defp current_schedule,
    do: %{
      "date" => "2026-12-12",
      "start_time" => "12:00",
      "end_time" => "14:00",
      "venue" => "Current hall"
    }

  defp dump(id), do: Ecto.UUID.dump!(id)

  defp wait_for_lock_waiters(count) do
    outside_sandbox(fn ->
      Repo.query!(
        """
        DO $$
        DECLARE attempts int := 0;
        BEGIN
          LOOP
            EXIT WHEN (
              SELECT count(DISTINCT blocked.pid)
              FROM pg_locks blocked
              WHERE NOT blocked.granted AND blocked.pid <> pg_backend_pid()
            ) >= #{count};
            attempts := attempts + 1;
            IF attempts > 500 THEN
              RAISE EXCEPTION 'fewer than #{count} backends queued behind the held lock';
            END IF;
            PERFORM pg_sleep(0.01);
            PERFORM pg_stat_clear_snapshot();
          END LOOP;
        END
        $$
        """,
        []
      )
    end)

    :ok
  end

  defp cleanup!(ctx) do
    ids = cleanup_ids(ctx)
    delete_fixture_jobs!(ids)
    delete_calendar_event!(ids.workshop_id)
    delete_workshop_fixtures!(ids)
    delete_principal_fixtures!(ids)
  end

  defp cleanup_ids(ctx) do
    intake_ids = Enum.map(ctx.intakes, & &1.id)

    %{
      workshop_id: ctx.workshop.id,
      staff_id: ctx.staff,
      intake_ids: intake_ids,
      person_ids: Enum.map(ctx.people, & &1.id),
      emails: Enum.map(ctx.people, & &1.email),
      payment_ids: Enum.map(ctx.payments, & &1.id),
      batch_ids:
        Repo.all(from(b in Batch, where: b.workshop_id == ^ctx.workshop.id, select: b.id)),
      refund_ids: refund_ids(intake_ids),
      notification_ids: notification_ids(ctx.workshop.id, intake_ids)
    }
  end

  defp refund_ids(intake_ids),
    do: Repo.all(from(r in IntakeRefund, where: r.intake_id in ^intake_ids, select: r.id))

  defp notification_ids(workshop_id, intake_ids) do
    Repo.all(
      from(n in Notification, where: ^notification_match(workshop_id, intake_ids), select: n.id)
    )
  end

  defp notification_match(workshop_id, intake_ids) do
    intake_match =
      Enum.reduce(intake_ids, dynamic(false), fn intake_id, match ->
        dynamic([n], ^match or like(n.notification_key, ^"beginners-intake:#{intake_id}:%"))
      end)

    dynamic(
      [n],
      like(n.notification_key, ^"beginners-workshop:#{workshop_id}:%") or ^intake_match
    )
  end

  defp delete_fixture_jobs!(ids) do
    Repo.delete_all(
      from(j in Oban.Job,
        where:
          fragment("?->>'source_id'", j.args) == ^ids.workshop_id or
            fragment("?->>'round_id'", j.args) in ^ids.batch_ids or
            fragment("?->>'refund_id'", j.args) in ^ids.refund_ids or
            fragment("?->>'email'", j.args) in ^ids.emails or
            fragment("?->>'notification_id'", j.args) in ^ids.notification_ids
      )
    )
  end

  defp delete_calendar_event!(workshop_id) do
    Repo.delete_all(
      from(e in Event,
        where: e.source_kind == "beginners_workshop" and e.source_id == ^workshop_id
      )
    )
  end

  defp delete_workshop_fixtures!(ids) do
    Repo.delete_all(from(r in IntakeRefund, where: r.intake_id in ^ids.intake_ids))
    Repo.delete_all(from(e in IntakeEvent, where: e.intake_id in ^ids.intake_ids))
    Repo.delete_all(from(l in IntakeEmailLog, where: l.intake_id in ^ids.intake_ids))

    # Confirmed credits point both ways (Intake → Carried Fee and Carried Fee
    # → Intake). This is teardown only; remove the temporary entitlement
    # before deleting either side of that relationship.
    Repo.update_all(
      from(i in Intake, where: i.id in ^ids.intake_ids and not is_nil(i.carried_fee_id)),
      set: [state: "lapsed", paid_via: nil, paid_at: nil, carried_fee_id: nil]
    )

    Repo.delete_all(
      from(f in CarriedFee,
        where: f.payment_id in ^ids.payment_ids or f.waitlist_id in ^ids.person_ids
      )
    )

    Repo.delete_all(from(p in IntakePayment, where: p.id in ^ids.payment_ids))
    Repo.delete_all(from(i in Intake, where: i.id in ^ids.intake_ids))
    Repo.delete_all(from(b in Batch, where: b.workshop_id == ^ids.workshop_id))
    Repo.delete_all(from(w in BeginnersWorkshop, where: w.id == ^ids.workshop_id))
  end

  defp delete_principal_fixtures!(ids) do
    Repo.delete_all(
      from(n in Notification,
        where: n.id in ^ids.notification_ids or n.principal_id == ^ids.staff_id
      )
    )

    # MemberProfile is keyed by the principal id, not the UserProfile id.
    Repo.delete_all(from(m in MemberProfile, where: m.id == ^ids.staff_id))

    Repo.delete_all(
      from(p in UserProfile,
        where: p.waitlist_id in ^ids.person_ids or p.principal_id == ^ids.staff_id
      )
    )

    Repo.delete_all(from(w in WaitlistEntry, where: w.id in ^ids.person_ids))
    Repo.delete_all(from(r in UserRole, where: r.principal_id == ^ids.staff_id))
    Repo.delete_all(from(p in Principal, where: p.id == ^ids.staff_id))
  end
end
