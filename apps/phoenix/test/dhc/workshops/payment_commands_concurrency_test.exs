defmodule Dhc.Workshops.PaymentCommandsConcurrencyTest do
  @moduledoc """
  ALE-340 (ADR 0027): lock order, transaction scope and races of
  `Dhc.Workshops.PaymentCommands`.

  Lock-order and write-outside-transaction facts are read from query
  telemetry (`Dhc.Workshops.PaymentLockTrace`). Races run on real connections
  outside the SQL sandbox (`Dhc.ConcurrencyHelpers`), because a sandboxed
  connection serializes everything and cannot show a lock bug; a telemetry
  pause makes each interleaving deterministic.

  These replaced the characterization tests that pinned the defects: member
  and external completion locking the Payment Attempt before the Workshop,
  `policy_failed` written outside a transaction, `cancel_workshop` raising on
  a concurrently requested Refund, member cancellation overwriting a refunded
  Registration, and a stale submission result overwriting a completed Refund.
  """

  use Dhc.DataCase, async: false

  import Dhc.ConcurrencyHelpers

  alias Dhc.Auth.Principal
  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.WorkshopFixtures
  alias Dhc.Workshops

  alias Dhc.Workshops.{
    ExternalUser,
    PaymentAttempt,
    PaymentLockTrace,
    Refund,
    Registration,
    StripeStub,
    Workshop
  }

  alias Dhc.Workshops.Workers.RefundWorker

  setup do
    on_exit(StripeStub.install())
    :ok
  end

  describe "lock order" do
    test "member completion locks the Workshop before the Payment Attempt" do
      workshop = WorkshopFixtures.workshop_fixture(status: "published", price_member: 1800.0)
      %{auth_user_id: member_id} = WorkshopFixtures.member_fixture()
      pi = start_member_payment!(workshop, member_id)

      {result, events} =
        PaymentLockTrace.trace(fn ->
          Workshops.complete_member_registration(workshop.id, member_id, pi)
        end)

      assert {:ok, %Registration{}} = result
      assert PaymentLockTrace.upward_locks(events) == []

      assert [["club_activities", "club_activity_payment_attempts"]] =
               PaymentLockTrace.transactions(events)
    end

    test "external completion locks the Workshop before the Payment Attempt in both transactions" do
      workshop = public_workshop_fixture()
      cs = start_external_payment!(workshop)

      {result, events} =
        PaymentLockTrace.trace(fn ->
          Workshops.complete_external_registration(workshop.id, cs)
        end)

      assert {:ok, %Registration{}} = result
      assert PaymentLockTrace.upward_locks(events) == []

      assert [
               ["club_activities", "club_activity_payment_attempts"],
               ["club_activities", "club_activity_payment_attempts"]
             ] = PaymentLockTrace.transactions(events)
    end

    test "starting a member payment again locks the Workshop before the existing Attempt" do
      workshop = WorkshopFixtures.workshop_fixture(status: "published", price_member: 1800.0)
      %{auth_user_id: member_id} = WorkshopFixtures.member_fixture()
      pi = start_member_payment!(workshop, member_id)

      {result, events} =
        PaymentLockTrace.trace(fn ->
          Workshops.create_member_payment_intent(workshop.id, member_id, %{})
        end)

      assert {:ok, %{payment_intent_id: ^pi}} = result

      assert [["club_activities", "club_activity_payment_attempts"]] =
               PaymentLockTrace.transactions(events)
    end

    test "Registration and Workshop Refund commands never lock upward" do
      workshop = WorkshopFixtures.workshop_fixture(status: "published")
      %{auth_user_id: member_id, principal_id: coordinator} = WorkshopFixtures.member_fixture()
      %{auth_user_id: other_id} = WorkshopFixtures.member_fixture()
      first = paid_registration!(workshop, member_id)
      paid_registration!(workshop, other_id)

      {result, refund_events} =
        PaymentLockTrace.trace(fn ->
          Workshops.process_refund(workshop.id, first.id, "Unable to attend", coordinator)
        end)

      assert {:ok, %Refund{}} = result

      assert [["club_activities", "club_activity_registrations", "club_activity_refunds"]] =
               PaymentLockTrace.transactions(refund_events)

      {result, cancel_events} =
        PaymentLockTrace.trace(fn -> Workshops.cancel_workshop(workshop.id, coordinator) end)

      assert {:ok, %Workshop{status: "cancelled"}} = result
      assert PaymentLockTrace.upward_locks(cancel_events) == []

      {result, member_events} =
        PaymentLockTrace.trace(fn ->
          Workshops.cancel_member_registration(workshop.id, other_id)
        end)

      assert {:error, :not_found} = result
      assert PaymentLockTrace.upward_locks(member_events) == []
    end

    test "Refund progression locks what the Refund points to and never the Workshop" do
      workshop =
        WorkshopFixtures.workshop_fixture(
          status: "published",
          price_member: 1800.0,
          max_capacity: 1
        )

      %{auth_user_id: member_id} = WorkshopFixtures.member_fixture()
      %{auth_user_id: other_id} = WorkshopFixtures.member_fixture()
      pi = start_member_payment!(workshop, member_id)
      paid_registration!(workshop, other_id)

      assert {:error, :compensation_pending} =
               Workshops.complete_member_registration(workshop.id, member_id, pi)

      refund = Repo.get_by!(Refund, stripe_payment_intent_id: pi)

      {result, submit_events} =
        PaymentLockTrace.trace(fn ->
          RefundWorker.perform(%Oban.Job{args: %{"refund_id" => refund.id}})
        end)

      assert :ok = result

      {result, event_events} =
        PaymentLockTrace.trace(fn ->
          Workshops.apply_stripe_refund_event(%{
            "id" => "re_" <> refund.id,
            "status" => "succeeded"
          })
        end)

      assert :ok = result
      assert %{status: "refunded"} = Repo.get_by!(PaymentAttempt, stripe_payment_intent_id: pi)

      for events <- [submit_events, event_events],
          tables <- PaymentLockTrace.transactions(events) do
        assert tables == ["club_activity_payment_attempts", "club_activity_refunds"]
      end
    end
  end

  describe "transaction scope" do
    test "an amount mismatch writes policy_failed inside the conclusion's transaction" do
      workshop = WorkshopFixtures.workshop_fixture(status: "published", price_member: 1800.0)
      %{auth_user_id: member_id} = WorkshopFixtures.member_fixture()
      pi = start_member_payment!(workshop, member_id, %{"amount" => 1})

      {result, events} =
        PaymentLockTrace.trace(fn ->
          Workshops.complete_member_registration(workshop.id, member_id, pi)
        end)

      assert {:error, :payment_metadata_mismatch} = result
      assert PaymentLockTrace.writes_outside_transaction(events) == []

      assert %{status: "policy_failed"} =
               Repo.get_by!(PaymentAttempt, stripe_payment_intent_id: pi)
    end
  end

  describe "member completion vs external completion" do
    test "two completions racing for the last place conclude once each without deadlock" do
      committed(
        [max_capacity: 1, is_public: true, price_member: 1800.0, price_non_member: 2400.0],
        fn ctx ->
          member_id = ctx.member.auth_user_id
          pi = "pi_race_#{System.unique_integer([:positive])}"

          StripeStub.put_object(
            :payment_intents,
            StripeStub.member_payment_intent(pi, ctx.workshop.id, member_id)
          )

          cs = start_external_payment!(ctx.workshop)

          results =
            hold_lock_then(
              "SELECT id FROM club_activities WHERE id = $1 FOR UPDATE",
              [Ecto.UUID.dump!(ctx.workshop.id)],
              [
                fn -> Workshops.complete_member_registration(ctx.workshop.id, member_id, pi) end,
                fn -> Workshops.complete_external_registration(ctx.workshop.id, cs) end
              ]
            )

          assert Enum.count(results, &match?({:ok, %Registration{}}, &1)) == 1
          assert Enum.count(results, &match?({:error, :compensation_pending}, &1)) == 1

          assert Repo.aggregate(
                   from(r in Registration, where: r.club_activity_id == ^ctx.workshop.id),
                   :count
                 ) == 1

          assert ~w(compensating registered) ==
                   from(pa in PaymentAttempt,
                     where: pa.club_activity_id == ^ctx.workshop.id,
                     order_by: pa.status,
                     select: pa.status
                   )
                   |> Repo.all()
        end
      )
    end
  end

  describe "cancel_workshop vs process_refund" do
    test "a requested Refund waits for the cancellation and finds the Registration refunded" do
      committed(fn ctx ->
        registration = paid_registration!(ctx.workshop, ctx.member.auth_user_id)
        supervisor = start_supervised!(Task.Supervisor)
        parent = self()

        cancel =
          Task.Supervisor.async_nolink(supervisor, fn ->
            outside_sandbox(fn ->
              PaymentLockTrace.pause_after(
                parent,
                PaymentLockTrace.query_on("club_activity_refunds")
              )

              Workshops.cancel_workshop(ctx.workshop.id, ctx.coordinator)
            end)
          end)

        assert_receive {:paused, cancel_pid}, 5_000

        refund =
          Task.Supervisor.async_nolink(supervisor, fn ->
            outside_sandbox(fn ->
              Workshops.process_refund(
                ctx.workshop.id,
                registration.id,
                "Unable to attend",
                ctx.coordinator
              )
            end)
          end)

        :ok = wait_for_lock_waiter("%club_activities%")
        send(cancel_pid, :resume)

        assert {:ok, {:ok, %Workshop{status: "cancelled"}}} = Task.yield(cancel, 5_000)
        assert {:ok, {:error, :already_refunded}} = Task.yield(refund, 5_000)
        assert [%Refund{refund_reason: "Workshop cancelled"}] = refunds_for(registration)
      end)
    end

    test "racing freely, exactly one Refund is recorded and neither command raises" do
      committed(fn ctx ->
        registration = paid_registration!(ctx.workshop, ctx.member.auth_user_id)

        results =
          hold_lock_then(
            "SELECT id FROM club_activities WHERE id = $1 FOR UPDATE",
            [Ecto.UUID.dump!(ctx.workshop.id)],
            [
              fn -> Workshops.cancel_workshop(ctx.workshop.id, ctx.coordinator) end,
              fn ->
                Workshops.process_refund(
                  ctx.workshop.id,
                  registration.id,
                  "Unable to attend",
                  ctx.coordinator
                )
              end
            ]
          )

        assert [{:ok, %Workshop{status: "cancelled"}}, refund_result] = results

        assert match?({:ok, %Refund{}}, refund_result) or
                 refund_result == {:error, :already_refunded}

        assert [%Refund{}] = refunds_for(registration)
        assert %{status: "refunded"} = Repo.get!(Registration, registration.id)
      end)
    end
  end

  describe "member cancellation vs Refund" do
    test "a member cancelling first holds the lock; the Workshop cancellation then owes nothing" do
      committed([start_in_days: 1], fn ctx ->
        registration = paid_registration!(ctx.workshop, ctx.member.auth_user_id)
        supervisor = start_supervised!(Task.Supervisor)
        parent = self()

        member_cancel =
          Task.Supervisor.async_nolink(supervisor, fn ->
            outside_sandbox(fn ->
              PaymentLockTrace.pause_after(
                parent,
                PaymentLockTrace.query_on("club_activity_registrations")
              )

              Workshops.cancel_member_registration(ctx.workshop.id, ctx.member.auth_user_id)
            end)
          end)

        assert_receive {:paused, member_pid}, 5_000

        cancel =
          Task.Supervisor.async_nolink(supervisor, fn ->
            outside_sandbox(fn -> Workshops.cancel_workshop(ctx.workshop.id, ctx.coordinator) end)
          end)

        :ok = wait_for_lock_waiter("%club_activities%")
        send(member_pid, :resume)

        assert {:ok, {:ok, %{refund_pending: false}}} = Task.yield(member_cancel, 5_000)
        assert {:ok, {:ok, %Workshop{status: "cancelled"}}} = Task.yield(cancel, 5_000)
        assert %{status: "cancelled"} = Repo.get!(Registration, registration.id)
        assert refunds_for(registration) == []
      end)
    end

    test "a member cancelling after the Workshop cancellation finds no active Registration" do
      committed([start_in_days: 1], fn ctx ->
        registration = paid_registration!(ctx.workshop, ctx.member.auth_user_id)
        supervisor = start_supervised!(Task.Supervisor)
        parent = self()

        cancel =
          Task.Supervisor.async_nolink(supervisor, fn ->
            outside_sandbox(fn ->
              PaymentLockTrace.pause_after(
                parent,
                PaymentLockTrace.query_on("club_activity_refunds")
              )

              Workshops.cancel_workshop(ctx.workshop.id, ctx.coordinator)
            end)
          end)

        assert_receive {:paused, cancel_pid}, 5_000

        member_cancel =
          Task.Supervisor.async_nolink(supervisor, fn ->
            outside_sandbox(fn ->
              Workshops.cancel_member_registration(ctx.workshop.id, ctx.member.auth_user_id)
            end)
          end)

        :ok = wait_for_lock_waiter("%club_activities%")
        send(cancel_pid, :resume)

        assert {:ok, {:ok, %Workshop{status: "cancelled"}}} = Task.yield(cancel, 5_000)
        assert {:ok, {:error, :not_found}} = Task.yield(member_cancel, 5_000)
        assert %{status: "refunded"} = Repo.get!(Registration, registration.id)
        assert [%Refund{status: "pending"}] = refunds_for(registration)
      end)
    end

    test "a member cancellation racing a requested Refund records at most one Refund" do
      committed(fn ctx ->
        registration = paid_registration!(ctx.workshop, ctx.member.auth_user_id)

        results =
          hold_lock_then(
            "SELECT id FROM club_activities WHERE id = $1 FOR UPDATE",
            [Ecto.UUID.dump!(ctx.workshop.id)],
            [
              fn ->
                Workshops.cancel_member_registration(ctx.workshop.id, ctx.member.auth_user_id)
              end,
              fn ->
                Workshops.process_refund(
                  ctx.workshop.id,
                  registration.id,
                  "Coordinator refund",
                  ctx.coordinator
                )
              end
            ]
          )

        assert Enum.all?(results, &match?({_tag, _value}, &1))
        assert [%Refund{}] = refunds_for(registration)
        assert %{status: "refunded"} = Repo.get!(Registration, registration.id)
      end)
    end
  end

  describe "stale Refund submission" do
    test "a stale submission result cannot reopen a completed Refund" do
      committed(fn ctx ->
        registration =
          paid_registration!(ctx.workshop, ctx.member.auth_user_id,
            stripe_payment_intent_id: "pi_stale_#{System.unique_integer([:positive])}"
          )

        {:ok, refund} =
          Workshops.process_refund(
            ctx.workshop.id,
            registration.id,
            "Unable to attend",
            ctx.coordinator
          )

        supervisor = start_supervised!(Task.Supervisor)
        parent = self()
        calls = :counters.new(1, [])

        StripeStub.put(:create_refund, fn _params ->
          :counters.add(calls, 1, 1)
          id = "re_" <> refund.id

          if :counters.get(calls, 1) == 1 do
            send(parent, {:paused, self()})
            receive do: (:resume -> {:ok, %{"id" => id, "status" => "pending"}})
          else
            {:ok, %{"id" => id, "status" => "succeeded"}}
          end
        end)

        stale =
          Task.Supervisor.async_nolink(supervisor, fn ->
            outside_sandbox(fn ->
              RefundWorker.perform(%Oban.Job{args: %{"refund_id" => refund.id}})
            end)
          end)

        assert_receive {:paused, stale_pid}, 5_000
        assert :ok = RefundWorker.perform(%Oban.Job{args: %{"refund_id" => refund.id}})
        assert %{status: "completed"} = Repo.get!(Refund, refund.id)

        send(stale_pid, :resume)
        assert {:ok, :ok} = Task.yield(stale, 5_000)
        assert %{status: "completed", provider_status: "succeeded"} = Repo.get!(Refund, refund.id)
      end)
    end
  end

  # ── Fixtures ─────────────────────────────────────────────────────────

  defp public_workshop_fixture do
    WorkshopFixtures.workshop_fixture(
      status: "published",
      is_public: true,
      price_non_member: 2400.0,
      max_capacity: 5
    )
  end

  defp start_member_payment!(workshop, member_id, overrides \\ %{}) do
    {:ok, %{payment_intent_id: pi}} =
      Workshops.create_member_payment_intent(workshop.id, member_id, %{})

    StripeStub.put_object(
      :payment_intents,
      StripeStub.member_payment_intent(pi, workshop.id, member_id, overrides)
    )

    pi
  end

  defp start_external_payment!(workshop) do
    attempt_id = Ecto.UUID.generate()

    {:ok, %{checkout_session_id: cs}} =
      Workshops.create_external_checkout_session(
        workshop.id,
        attempt_id,
        "https://example.com/confirmation?session_id={CHECKOUT_SESSION_ID}"
      )

    StripeStub.put_object(
      :checkout_sessions,
      StripeStub.checkout_session(cs, workshop.id, attempt_id)
    )

    cs
  end

  defp paid_registration!(workshop, member_id, attrs \\ []) do
    WorkshopFixtures.registration_fixture(
      Keyword.merge(
        [
          workshop_id: workshop.id,
          member_user_id: member_id,
          status: "confirmed",
          amount_paid: 1800
        ],
        attrs
      )
    )
  end

  defp refunds_for(registration),
    do: Repo.all(from(r in Refund, where: r.registration_id == ^registration.id))

  # Commits a published Workshop, a member and a coordinator outside the
  # sandbox, runs `fun` there, and deletes everything it touched afterwards.
  defp committed(opts \\ [], fun) do
    {start_in_days, workshop_attrs} = Keyword.pop(opts, :start_in_days, 30)

    start =
      DateTime.utc_now() |> DateTime.add(start_in_days, :day) |> DateTime.truncate(:second)

    ctx =
      outside_sandbox(fn ->
        %{
          workshop:
            WorkshopFixtures.workshop_fixture(
              Keyword.merge(
                [status: "published", start_date: start, max_capacity: 5],
                workshop_attrs
              )
            ),
          member: WorkshopFixtures.member_fixture(),
          coordinator: WorkshopFixtures.member_fixture().principal_id
        }
      end)

    on_exit(fn -> outside_sandbox(fn -> cleanup!(ctx) end) end)
    outside_sandbox(fn -> fun.(ctx) end)
  end

  defp cleanup!(ctx) do
    workshop_id = ctx.workshop.id

    attempt_ids =
      Repo.all(
        from(pa in PaymentAttempt, where: pa.club_activity_id == ^workshop_id, select: pa.id)
      )

    registrations = Repo.all(from(r in Registration, where: r.club_activity_id == ^workshop_id))
    registration_ids = Enum.map(registrations, & &1.id)
    external_user_ids = registrations |> Enum.map(& &1.external_user_id) |> Enum.reject(&is_nil/1)

    refund_ids =
      Repo.all(
        from(rf in Refund,
          where: rf.registration_id in ^registration_ids or rf.payment_attempt_id in ^attempt_ids,
          select: rf.id
        )
      )

    Repo.delete_all(
      from(j in Oban.Job, where: fragment("?->>'refund_id'", j.args) in ^refund_ids)
    )

    Repo.delete_all(from(rf in Refund, where: rf.id in ^refund_ids))
    Repo.delete_all(from(r in Registration, where: r.id in ^registration_ids))
    Repo.delete_all(from(pa in PaymentAttempt, where: pa.id in ^attempt_ids))
    Repo.delete_all(from(e in ExternalUser, where: e.id in ^external_user_ids))
    Repo.delete_all(from(w in Workshop, where: w.id == ^workshop_id))

    for principal_id <- [ctx.member.principal_id, ctx.coordinator] do
      Repo.delete_all(from(mp in MemberProfile, where: mp.id == ^principal_id))
      Repo.delete_all(from(up in UserProfile, where: up.principal_id == ^principal_id))
      Repo.delete_all(from(p in Principal, where: p.id == ^principal_id))
    end
  end
end
