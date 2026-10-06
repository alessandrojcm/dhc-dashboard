defmodule Dhc.Workshops.PaymentCommandsConcurrencyTest do
  @moduledoc """
  ALE-340 characterization: pins today's Workshop payment defects before
  `Dhc.Workshops.PaymentCommands` replaces them (ADR 0027).

  Lock-order and write-outside-transaction facts are read from query
  telemetry (`Dhc.Workshops.PaymentLockTrace`). Races run on real connections
  outside the SQL sandbox (`Dhc.ConcurrencyHelpers`), because a sandboxed
  connection serializes everything and cannot show a lock bug; a telemetry
  pause makes each interleaving deterministic.
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

  describe "lock order (characterization)" do
    test "member completion locks the Payment Attempt before the Workshop" do
      workshop = WorkshopFixtures.workshop_fixture(status: "published", price_member: 1800.0)
      %{auth_user_id: member_id} = WorkshopFixtures.member_fixture()

      {:ok, %{payment_intent_id: pi}} =
        Workshops.create_member_payment_intent(workshop.id, member_id, %{})

      StripeStub.put_object(
        :payment_intents,
        StripeStub.member_payment_intent(pi, workshop.id, member_id)
      )

      {result, events} =
        PaymentLockTrace.trace(fn ->
          Workshops.complete_member_registration(workshop.id, member_id, pi)
        end)

      assert {:ok, %Registration{}} = result
      assert "club_activities" in PaymentLockTrace.upward_locks(events)
    end

    test "external completion locks the Payment Attempt before the Workshop" do
      workshop = public_workshop_fixture()
      attempt_id = Ecto.UUID.generate()

      {:ok, %{checkout_session_id: cs}} =
        Workshops.create_external_checkout_session(workshop.id, attempt_id, return_url())

      StripeStub.put_object(
        :checkout_sessions,
        StripeStub.checkout_session(cs, workshop.id, attempt_id)
      )

      {result, events} =
        PaymentLockTrace.trace(fn ->
          Workshops.complete_external_registration(workshop.id, cs)
        end)

      assert {:ok, %Registration{}} = result
      assert "club_activities" in PaymentLockTrace.upward_locks(events)
    end

    test "starting a member payment again locks the existing Attempt and never the Workshop" do
      workshop = WorkshopFixtures.workshop_fixture(status: "published", price_member: 1800.0)
      %{auth_user_id: member_id} = WorkshopFixtures.member_fixture()

      {:ok, %{payment_intent_id: pi}} =
        Workshops.create_member_payment_intent(workshop.id, member_id, %{})

      StripeStub.put_object(
        :payment_intents,
        StripeStub.member_payment_intent(pi, workshop.id, member_id)
      )

      {result, events} =
        PaymentLockTrace.trace(fn ->
          Workshops.create_member_payment_intent(workshop.id, member_id, %{})
        end)

      assert {:ok, %{payment_intent_id: ^pi}} = result
      assert [["club_activity_payment_attempts"]] = PaymentLockTrace.transactions(events)
    end
  end

  describe "writes outside a transaction (characterization)" do
    test "an amount mismatch writes policy_failed with no transaction" do
      workshop = WorkshopFixtures.workshop_fixture(status: "published", price_member: 1800.0)
      %{auth_user_id: member_id} = WorkshopFixtures.member_fixture()

      {:ok, %{payment_intent_id: pi}} =
        Workshops.create_member_payment_intent(workshop.id, member_id, %{})

      StripeStub.put_object(
        :payment_intents,
        StripeStub.member_payment_intent(pi, workshop.id, member_id, %{"amount" => 1})
      )

      {result, events} =
        PaymentLockTrace.trace(fn ->
          Workshops.complete_member_registration(workshop.id, member_id, pi)
        end)

      assert {:error, :payment_metadata_mismatch} = result

      assert "club_activity_payment_attempts" in PaymentLockTrace.writes_outside_transaction(
               events
             )

      assert %{status: "policy_failed"} =
               Repo.get_by!(PaymentAttempt, stripe_payment_intent_id: pi)
    end
  end

  describe "duplicate-Refund race (characterization)" do
    test "a requested Refund committing inside cancel_workshop's check makes it raise" do
      committed(fn ctx ->
        registration = paid_registration!(ctx.workshop, ctx.member)
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

        assert {:ok, %Refund{}} =
                 Workshops.process_refund(
                   ctx.workshop.id,
                   registration.id,
                   "Unable to attend",
                   ctx.coordinator
                 )

        send(cancel_pid, :resume)

        assert {:exit,
                {%Ecto.ConstraintError{constraint: "club_activity_refunds_registration_id_index"},
                 _}} =
                 Task.yield(cancel, 5_000)

        assert Repo.aggregate(
                 from(r in Refund, where: r.registration_id == ^registration.id),
                 :count
               ) == 1
      end)
    end
  end

  describe "checks before the lock (characterization)" do
    test "member cancellation decides on an unlocked read and overwrites a refunded Registration" do
      committed([start_in_days: 1], fn ctx ->
        registration = paid_registration!(ctx.workshop, ctx.member)
        supervisor = start_supervised!(Task.Supervisor)
        parent = self()

        member_cancel =
          Task.Supervisor.async_nolink(supervisor, fn ->
            outside_sandbox(fn ->
              PaymentLockTrace.pause_after(parent, &refund_eligibility_read?/1)
              Workshops.cancel_member_registration(ctx.workshop.id, ctx.member.auth_user_id)
            end)
          end)

        assert_receive {:paused, member_pid}, 5_000

        assert {:ok, %Workshop{status: "cancelled"}} =
                 Workshops.cancel_workshop(ctx.workshop.id, ctx.coordinator)

        assert %{status: "refunded"} = Repo.get!(Registration, registration.id)

        send(member_pid, :resume)

        assert {:ok, {:ok, %{refund_pending: false}}} = Task.yield(member_cancel, 5_000)
        assert %{status: "cancelled"} = Repo.get!(Registration, registration.id)
        assert %Refund{status: "pending"} = Repo.get_by!(Refund, registration_id: registration.id)
      end)
    end
  end

  describe "scattered Refund status writes (characterization)" do
    test "a stale submission result overwrites a completed Refund" do
      committed(fn ctx ->
        registration =
          paid_registration!(ctx.workshop, ctx.member,
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

        StripeStub.put(:create_refund, fn params ->
          :counters.add(calls, 1, 1)
          id = "re_" <> refund.id

          if :counters.get(calls, 1) == 1 do
            send(parent, {:paused, self()})
            receive do: (:resume -> {:ok, %{"id" => id, "status" => "pending"}})
          else
            _ = params
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
        assert %{status: "processing"} = Repo.get!(Refund, refund.id)
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

  defp return_url, do: "https://example.com/confirmation?session_id={CHECKOUT_SESSION_ID}"

  defp refund_eligibility_read?(meta) do
    meta.source == "club_activity_registrations" and is_binary(meta.query) and
      meta.query =~ ~s(JOIN "club_activities")
  end

  defp paid_registration!(workshop, member, attrs \\ []) do
    WorkshopFixtures.registration_fixture(
      Keyword.merge(
        [
          workshop_id: workshop.id,
          member_user_id: member.auth_user_id,
          status: "confirmed",
          amount_paid: 1800
        ],
        attrs
      )
    )
  end

  # Commits a published Workshop, a member and a coordinator outside the
  # sandbox, runs `fun` there, and deletes everything it touched afterwards.
  defp committed(opts \\ [], fun) do
    start =
      DateTime.utc_now()
      |> DateTime.add(Keyword.get(opts, :start_in_days, 30), :day)
      |> DateTime.truncate(:second)

    ctx =
      outside_sandbox(fn ->
        %{
          workshop:
            WorkshopFixtures.workshop_fixture(
              status: "published",
              start_date: start,
              max_capacity: 5
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

    registration_ids =
      Repo.all(from(r in Registration, where: r.club_activity_id == ^workshop_id, select: r.id))

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
    Repo.delete_all(from(w in Workshop, where: w.id == ^workshop_id))

    for principal_id <- [ctx.member.principal_id, ctx.coordinator] do
      Repo.delete_all(from(mp in MemberProfile, where: mp.id == ^principal_id))
      Repo.delete_all(from(up in UserProfile, where: up.principal_id == ^principal_id))
      Repo.delete_all(from(p in Principal, where: p.id == ^principal_id))
    end
  end
end
