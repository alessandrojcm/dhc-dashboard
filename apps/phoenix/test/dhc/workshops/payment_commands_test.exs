defmodule Dhc.Workshops.PaymentCommandsTest do
  @moduledoc """
  ALE-340: the transition table, actor authorization and constraint
  translation of `Dhc.Workshops.PaymentCommands`, exercised through
  `execute/2` (directly or through the `Dhc.Workshops` functions and workers
  that delegate to it).
  """

  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  alias Dhc.Repo
  alias Dhc.WorkshopFixtures
  alias Dhc.Workshops

  alias Dhc.Workshops.{
    PaymentAttempt,
    PaymentCommands,
    Refund,
    Registration,
    StripeStub,
    Workshop
  }

  alias Dhc.Workshops.Workers.{RefundReconciliationWorker, RefundWorker}

  setup do
    on_exit(StripeStub.install())
    :ok
  end

  describe "the transition table" do
    test "declares exactly the ADR 0027 Payment Attempt and Refund transitions" do
      attempt_statuses = ~w(pending paid registered compensating refunded policy_failed)
      refund_statuses = ~w(pending processing completed failed cancelled)

      legal_attempts =
        for from <- attempt_statuses,
            to <- attempt_statuses,
            PaymentCommands.transition_allowed?(PaymentAttempt, from, to),
            do: {from, to}

      assert Enum.sort(legal_attempts) ==
               Enum.sort([
                 {"pending", "paid"},
                 {"pending", "policy_failed"},
                 {"paid", "registered"},
                 {"paid", "compensating"},
                 {"paid", "policy_failed"},
                 {"compensating", "refunded"}
               ])

      legal_refunds =
        for from <- refund_statuses,
            to <- refund_statuses,
            PaymentCommands.transition_allowed?(Refund, from, to),
            do: {from, to}

      assert Enum.sort(legal_refunds) ==
               Enum.sort([
                 {"pending", "processing"},
                 {"pending", "completed"},
                 {"pending", "failed"},
                 {"pending", "cancelled"},
                 {"processing", "completed"},
                 {"processing", "failed"},
                 {"processing", "cancelled"}
               ])
    end
  end

  describe "Payment Attempt transitions through execute/2" do
    setup do
      workshop =
        WorkshopFixtures.workshop_fixture(
          status: "published",
          price_member: 1800.0,
          max_capacity: 2
        )

      %{auth_user_id: member_id} = WorkshopFixtures.member_fixture()
      %{workshop: workshop, member_id: member_id}
    end

    test "pending → paid, then paid → policy_failed", %{workshop: workshop, member_id: member_id} do
      pi = start_member_payment!(workshop, member_id)

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: member_id,
        status: "confirmed"
      )

      assert {:error, :already_registered} = complete_member(workshop, member_id, pi)
      assert %{status: "paid", paid_at: %DateTime{}} = attempt_for(pi)

      put_payment_intent(pi, workshop, member_id, %{"amount" => 1})
      assert {:error, :payment_metadata_mismatch} = complete_member(workshop, member_id, pi)
      assert %{status: "policy_failed"} = attempt_for(pi)
    end

    test "pending → policy_failed, and policy_failed is terminal", ctx do
      pi = start_member_payment!(ctx.workshop, ctx.member_id, %{"amount" => 1})

      assert {:error, :payment_metadata_mismatch} =
               complete_member(ctx.workshop, ctx.member_id, pi)

      assert %{status: "policy_failed"} = attempt_for(pi)

      put_payment_intent(pi, ctx.workshop, ctx.member_id)

      assert {:error, :payment_metadata_mismatch} =
               complete_member(ctx.workshop, ctx.member_id, pi)

      assert %{status: "policy_failed", concluded_at: nil} = attempt_for(pi)
      assert Repo.aggregate(Registration, :count) == 0
    end

    test "paid → registered, and registered is terminal", ctx do
      pi = start_member_payment!(ctx.workshop, ctx.member_id)

      assert {:ok, registration} = complete_member(ctx.workshop, ctx.member_id, pi)
      assert %{status: "registered", concluded_at: %DateTime{}} = attempt_for(pi)

      put_payment_intent(pi, ctx.workshop, ctx.member_id, %{"amount" => 1})

      assert {:error, :payment_metadata_mismatch} =
               complete_member(ctx.workshop, ctx.member_id, pi)

      assert %{status: "registered"} = attempt_for(pi)
      assert %{status: "confirmed"} = Repo.get!(Registration, registration.id)
    end

    test "paid → compensating → refunded, and both ignore later completions", ctx do
      ctx.workshop |> Ecto.Changeset.change(max_capacity: 1) |> Repo.update!()
      pi = start_member_payment!(ctx.workshop, ctx.member_id)
      %{auth_user_id: other_id} = WorkshopFixtures.member_fixture()

      WorkshopFixtures.registration_fixture(
        workshop_id: ctx.workshop.id,
        member_user_id: other_id,
        status: "confirmed"
      )

      assert {:error, :compensation_pending} = complete_member(ctx.workshop, ctx.member_id, pi)
      assert %{status: "compensating"} = attempt_for(pi)

      assert {:error, :compensation_pending} = complete_member(ctx.workshop, ctx.member_id, pi)
      assert %{status: "compensating"} = attempt_for(pi)

      refund = Repo.get_by!(Refund, payment_attempt_id: attempt_for(pi).id)
      assert {:ok, :submitted} = PaymentCommands.execute(:system, {:submit_refund, refund.id})
      assert %{status: "processing"} = Repo.get!(Refund, refund.id)
      assert %{status: "compensating"} = attempt_for(pi)

      assert {:ok, %Refund{status: "completed"}} = refund_event("re_" <> refund.id, "succeeded")
      assert %{status: "refunded"} = attempt_for(pi)

      assert {:error, :compensation_pending} = complete_member(ctx.workshop, ctx.member_id, pi)
      assert {:ok, %Refund{status: "completed"}} = refund_event("re_" <> refund.id, "failed")
      assert %{status: "refunded"} = attempt_for(pi)
    end
  end

  describe "Refund transitions through execute/2" do
    setup do
      workshop = WorkshopFixtures.workshop_fixture(status: "published")
      %{auth_user_id: member_id} = WorkshopFixtures.member_fixture()

      registration =
        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          member_user_id: member_id,
          status: "refunded",
          amount_paid: 1800,
          stripe_payment_intent_id: "pi_#{System.unique_integer([:positive])}"
        )

      %{registration: registration}
    end

    for {from, provider, to} <- [
          {"pending", "pending", "processing"},
          {"pending", "requires_action", "processing"},
          {"pending", "succeeded", "completed"},
          {"pending", "failed", "failed"},
          {"pending", "canceled", "cancelled"},
          {"processing", "pending", "processing"},
          {"processing", "succeeded", "completed"},
          {"processing", "failed", "failed"},
          {"processing", "canceled", "cancelled"}
        ] do
      test "#{from} + Stripe #{provider} → #{to}", %{registration: registration} do
        refund = refund_in(registration, unquote(from))

        assert {:ok, %Refund{status: unquote(to), provider_status: unquote(provider)}} =
                 refund_event(refund.stripe_refund_id, unquote(provider))

        assert %{status: unquote(to)} = Repo.get!(Refund, refund.id)
      end
    end

    for from <- ~w(completed failed cancelled),
        provider <- ~w(pending succeeded failed canceled) do
      test "terminal #{from} ignores a later Stripe #{provider}", %{registration: registration} do
        refund = refund_in(registration, unquote(from))

        assert {:ok, %Refund{status: unquote(from)}} =
                 refund_event(refund.stripe_refund_id, unquote(provider))

        assert Repo.get!(Refund, refund.id) == refund
      end
    end

    for from <- ~w(completed failed cancelled) do
      test "terminal #{from} is not resubmitted", %{registration: registration} do
        refund = refund_in(registration, unquote(from))
        StripeStub.put(:create_refund, fn _params -> flunk("terminal Refund submitted") end)

        assert {:ok, :settled} = PaymentCommands.execute(:system, {:submit_refund, refund.id})
        assert Repo.get!(Refund, refund.id) == refund
      end
    end

    test "submission accepted by Stripe: pending → processing", %{registration: registration} do
      refund = refund_in(registration, "pending", stripe_refund_id: nil)

      assert {:ok, :submitted} = PaymentCommands.execute(:system, {:submit_refund, refund.id})

      assert %{status: "processing", stripe_refund_id: "re_" <> _, processed_at: %DateTime{}} =
               Repo.get!(Refund, refund.id)
    end

    test "submission refunded at once: pending → completed", %{registration: registration} do
      refund = refund_in(registration, "pending", stripe_refund_id: nil)

      StripeStub.put(:create_refund, fn _ ->
        {:ok, %{"id" => "re_now_#{refund.id}", "status" => "succeeded"}}
      end)

      assert {:ok, :submitted} = PaymentCommands.execute(:system, {:submit_refund, refund.id})
      assert %{status: "completed", completed_at: %DateTime{}} = Repo.get!(Refund, refund.id)
    end

    test "a non-retryable rejection needs intervention: pending → failed", %{
      registration: registration
    } do
      refund = refund_in(registration, "pending", stripe_refund_id: nil)

      StripeStub.put(:create_refund, fn _ ->
        {:error, {:stripe_api, 400, "charge_already_refunded"}}
      end)

      assert {:error, {:intervention_required, {:stripe_api, 400, _}}} =
               PaymentCommands.execute(:system, {:submit_refund, refund.id})

      assert %{status: "failed", last_error: "{:stripe_api, 400" <> _} =
               Repo.get!(Refund, refund.id)
    end

    test "a retryable failure stays pending and records the error", %{registration: registration} do
      refund = refund_in(registration, "pending", stripe_refund_id: nil)
      reason = {:http_error, %Req.TransportError{reason: :timeout}}
      StripeStub.put(:create_refund, fn _ -> {:error, reason} end)

      assert {:error, ^reason} = PaymentCommands.execute(:system, {:submit_refund, refund.id})

      assert %{status: "pending", last_error: "{:http_error" <> _} =
               Repo.get!(Refund, refund.id)
    end

    # Dhc.Stripe.Failure.retryable?/1 is the one retry rule (ALE-342): a Stripe
    # 5xx/408/409/429 or transport failure retries; anything else, including a
    # failure that never reached Stripe, needs a human.
    test "a retryable Stripe answer stays pending", %{registration: registration} do
      refund = refund_in(registration, "pending", stripe_refund_id: nil)
      StripeStub.put(:create_refund, fn _ -> {:error, {:stripe_api, 429, %{}}} end)

      assert {:error, {:stripe_api, 429, _}} =
               PaymentCommands.execute(:system, {:submit_refund, refund.id})

      assert %{status: "pending"} = Repo.get!(Refund, refund.id)
    end

    test "a non-retryable failure outside the 4xx range needs intervention", %{
      registration: registration
    } do
      refund = refund_in(registration, "pending", stripe_refund_id: nil)
      StripeStub.put(:create_refund, fn _ -> {:error, :stripe_key_not_configured} end)

      assert {:error, {:intervention_required, :stripe_key_not_configured}} =
               PaymentCommands.execute(:system, {:submit_refund, refund.id})

      assert %{status: "failed", last_error: ":stripe_key_not_configured"} =
               Repo.get!(Refund, refund.id)
    end

    test "an event for an unknown Stripe refund is acknowledged" do
      assert {:ok, :unknown_refund} = refund_event("re_unknown", "succeeded")

      assert :ok =
               Workshops.apply_stripe_refund_event(%{
                 "id" => "re_unknown",
                 "status" => "succeeded"
               })
    end

    test "an event without id and status is rejected" do
      assert {:error, :invalid_refund_object} =
               Workshops.apply_stripe_refund_event(%{"id" => "re_x"})
    end
  end

  describe "actors" do
    test "every command refuses the wrong actor before any read" do
      id = Ecto.UUID.generate()

      for {actor, command} <- [
            {:external, {:start_member_payment, id, nil}},
            {{:coordinator, id}, {:complete_member_payment, id, "pi_x"}},
            {{:member, id}, {:start_external_payment, id, id, "x"}},
            {{:member, id}, {:request_refund, id, id, "x"}},
            {:system, {:cancel_workshop, id, & &1, :refund_owed}},
            {{:coordinator, nil}, {:cancel_workshop, id, & &1, :keep}},
            {{:coordinator, nil}, {:request_refund, id, id, "x"}},
            {{:coordinator, id}, {:submit_refund, id}},
            {:external, :reconcile_refunds}
          ] do
        assert {:error, :forbidden} = PaymentCommands.execute(actor, command)
      end

      assert {:error, :unknown_command} = PaymentCommands.execute(:system, {:refund_everything})
    end
  end

  describe "refund reconciliation" do
    setup do
      %{workshop: WorkshopFixtures.workshop_fixture(status: "published")}
    end

    test "handles at most `limit` Refunds, least recently written first", %{workshop: workshop} do
      newest = unresolved_refund(workshop, "processing", ~U[2026-10-03 00:00:00Z])
      oldest = unresolved_refund(workshop, "processing", ~U[2026-10-01 00:00:00Z])
      middle = unresolved_refund(workshop, "processing", ~U[2026-10-02 00:00:00Z])
      record_retrievals()

      assert {:ok, :reconciled} = PaymentCommands.execute(:system, {:reconcile_refunds, 2})

      assert retrieved() == [oldest.stripe_refund_id, middle.stripe_refund_id]
      assert %{status: "completed"} = Repo.get!(Refund, oldest.id)
      assert %{status: "completed"} = Repo.get!(Refund, middle.id)
      assert %{status: "processing"} = Repo.get!(Refund, newest.id)

      # The next pass carries on with what did not fit.
      assert {:ok, :reconciled} = PaymentCommands.execute(:system, :reconcile_refunds)
      assert retrieved() == [newest.stripe_refund_id]
      assert %{status: "completed"} = Repo.get!(Refund, newest.id)
    end

    test "orders ties by id and counts pending Refunds against the limit", %{workshop: workshop} do
      at = ~U[2026-10-01 00:00:00Z]

      [first, second, third] =
        [
          unresolved_refund(workshop, "pending", at),
          unresolved_refund(workshop, "processing", at),
          unresolved_refund(workshop, "processing", at)
        ]
        |> Enum.sort_by(& &1.id)

      _later = unresolved_refund(workshop, "pending", ~U[2026-10-02 00:00:00Z])
      record_retrievals()

      assert {:ok, :reconciled} = PaymentCommands.execute(:system, {:reconcile_refunds, 3})

      handled =
        retrieved() ++
          for(%{args: %{"refund_id" => id}} <- all_enqueued(worker: RefundWorker), do: id)

      assert Enum.sort(handled) ==
               Enum.sort(
                 for refund <- [first, second, third],
                     do:
                       if(refund.status == "pending",
                         do: refund.id,
                         else: refund.stripe_refund_id
                       )
               )
    end

    test "the cron worker cannot overlap an incomplete pass" do
      assert {:ok, %Oban.Job{conflict?: false}} = Oban.insert(RefundReconciliationWorker.new(%{}))
      assert {:ok, %Oban.Job{conflict?: true}} = Oban.insert(RefundReconciliationWorker.new(%{}))
    end
  end

  describe "constraint translation" do
    test "every index persist/1 translates exists" do
      %{rows: rows} =
        Repo.query!(
          "SELECT indexname FROM pg_indexes WHERE tablename = ANY($1)",
          [~w(club_activity_payment_attempts club_activity_registrations club_activity_refunds)]
        )

      existing = MapSet.new(rows, fn [name] -> name end)

      assert Enum.reject(PaymentCommands.declared_unique_indexes(), &MapSet.member?(existing, &1)) ==
               []
    end

    test "cancel_workshop reports a Refund written outside its lock as :already_requested" do
      workshop = WorkshopFixtures.workshop_fixture(status: "published")
      %{auth_user_id: member_id, principal_id: coordinator} = WorkshopFixtures.member_fixture()

      registration =
        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          member_user_id: member_id,
          status: "confirmed",
          amount_paid: 1800
        )

      # Stands in for a Refund committed by a writer that bypassed the lock.
      force_unique_violation!(
        "club_activity_refunds",
        "club_activity_refunds_registration_id_index"
      )

      assert {:error, :already_requested} = Workshops.cancel_workshop(workshop.id, coordinator)
      assert %{status: "published"} = Repo.get!(Workshop, workshop.id)
      assert %{status: "confirmed"} = Repo.get!(Registration, registration.id)
      assert all_enqueued(worker: RefundWorker) == []
    end

    test "a member Registration lost to the active-member index commits the paid attempt and reports it" do
      workshop =
        WorkshopFixtures.workshop_fixture(
          status: "published",
          price_member: 1800.0,
          max_capacity: 2
        )

      %{auth_user_id: member_id} = WorkshopFixtures.member_fixture()
      pi = start_member_payment!(workshop, member_id)

      force_unique_violation!(
        "club_activity_registrations",
        "club_activity_registrations_member_user_id_active_unique"
      )

      assert {:error, :already_registered} = complete_member(workshop, member_id, pi)
      assert %{status: "paid", paid_at: %DateTime{}} = attempt_for(pi)
      assert Repo.aggregate(Registration, :count) == 0
    end

    test "an external Registration lost to a unique index concludes with a compensating Refund" do
      workshop =
        WorkshopFixtures.workshop_fixture(
          status: "published",
          is_public: true,
          price_non_member: 2400.0,
          max_capacity: 2
        )

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

      force_unique_violation!(
        "club_activity_registrations",
        "club_activity_registrations_external_user_id_active_unique"
      )

      assert {:error, :compensation_pending} =
               Workshops.complete_external_registration(workshop.id, cs)

      assert %{status: "compensating"} = Repo.get!(PaymentAttempt, attempt_id)

      assert %Refund{status: "pending", refund_reason: "Attendee already registered"} =
               Repo.get_by!(Refund, payment_attempt_id: attempt_id)

      assert Repo.aggregate(Registration, :count) == 0
    end
  end

  describe "archived Workshops" do
    setup do
      workshop =
        WorkshopFixtures.workshop_fixture(
          status: "published",
          is_public: true,
          price_member: 1800.0,
          price_non_member: 2400.0
        )
        |> Ecto.Changeset.change(archived_at: DateTime.utc_now() |> DateTime.truncate(:second))
        |> Repo.update!()

      test_pid = self()

      StripeStub.put(:create_refund, fn params ->
        send(test_pid, {:create_refund, params})
        {:ok, %{"id" => "re_unexpected", "status" => "pending"}}
      end)

      %{workshop: workshop}
    end

    test "refuse member initiation and durably compensate a completed payment without calling Stripe",
         %{workshop: workshop} do
      %{auth_user_id: member_id} = WorkshopFixtures.member_fixture()

      assert {:error, :not_found} =
               Workshops.create_member_payment_intent(workshop.id, member_id, %{})

      pi = "pi_archived_#{System.unique_integer([:positive])}"
      put_payment_intent(pi, workshop, member_id)

      assert {:error, :compensation_pending} = complete_member(workshop, member_id, pi)

      assert %Refund{status: "pending"} =
               Repo.get_by!(Refund, payment_attempt_id: attempt_for(pi).id)

      refute_received {:create_refund, _}
    end

    test "close the external gate and compensate an in-flight paid Checkout from its Payment Intent",
         %{workshop: workshop} do
      assert %{can_register: false, reason: "NOT_FOUND"} =
               Workshops.external_registration_gate(workshop.id)

      assert {:error, :not_found} =
               Workshops.create_external_checkout_session(
                 workshop.id,
                 Ecto.UUID.generate(),
                 "https://example.com/return?session={CHECKOUT_SESSION_ID}"
               )

      cs = "cs_archived_#{System.unique_integer([:positive])}"
      attempt_id = Ecto.UUID.generate()

      Repo.insert!(%PaymentAttempt{
        id: attempt_id,
        club_activity_id: workshop.id,
        actor_type: "external",
        amount: 2400,
        currency: "eur",
        status: "paid",
        stripe_checkout_session_id: cs,
        paid_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      StripeStub.put_object(
        :checkout_sessions,
        StripeStub.checkout_session(cs, workshop.id, attempt_id)
      )

      assert {:error, :compensation_pending} =
               Workshops.complete_external_registration(workshop.id, cs)

      refund = Repo.get_by!(Refund, payment_attempt_id: attempt_id)
      assert refund.status == "pending"
      assert refund.stripe_payment_intent_id == "pi_for_#{cs}"
      refute_received {:create_refund, _}
    end
  end

  describe "external Registration Refunds" do
    test "resolve the Payment Intent from the Checkout Session at submission" do
      workshop = WorkshopFixtures.workshop_fixture(status: "published", is_public: true)
      external = WorkshopFixtures.external_user_fixture()
      %{principal_id: coordinator} = WorkshopFixtures.member_fixture()
      cs = "cs_refund_external_#{System.unique_integer([:positive])}"

      StripeStub.put_object(
        :checkout_sessions,
        StripeStub.checkout_session(cs, workshop.id, Ecto.UUID.generate())
      )

      registration =
        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          external_user_id: external.id,
          status: "confirmed",
          amount_paid: 2400,
          stripe_checkout_session_id: cs
        )

      assert {:ok, %Refund{status: "pending", stripe_payment_intent_id: nil} = refund} =
               Workshops.process_refund(workshop.id, registration.id, "External", coordinator)

      test_pid = self()

      StripeStub.put(:create_refund, fn params ->
        send(test_pid, {:create_refund, params})
        {:ok, %{"id" => "re_external", "status" => "pending"}}
      end)

      assert {:ok, :submitted} = PaymentCommands.execute(:system, {:submit_refund, refund.id})

      expected_pi = "pi_for_#{cs}"
      assert_received {:create_refund, %{body: body}}
      assert body[:payment_intent] == expected_pi
      assert %Refund{stripe_payment_intent_id: ^expected_pi} = Repo.get!(Refund, refund.id)
    end
  end

  describe "refund eligibility" do
    test "the advisory read and the locked command apply the same rule" do
      start = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)

      workshop =
        WorkshopFixtures.workshop_fixture(status: "published", start_date: start, refund_days: 3)

      %{auth_user_id: member_id, principal_id: coordinator} = WorkshopFixtures.member_fixture()

      registration =
        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          member_user_id: member_id,
          status: "confirmed",
          amount_paid: 1800
        )

      assert {:error, :deadline_passed} = Workshops.refund_eligibility(registration.id)

      assert {:error, :deadline_passed} =
               Workshops.process_refund(workshop.id, registration.id, "Late", coordinator)

      # The club's cancellation ignores the member's refund window.
      assert {:ok, %Workshop{status: "cancelled"}} =
               Workshops.cancel_workshop(workshop.id, coordinator)

      assert {:error, :already_refunded} = Workshops.refund_eligibility(registration.id)

      assert {:error, :already_refunded} =
               Workshops.process_refund(workshop.id, registration.id, "Again", coordinator)
    end

    test "the requested Refund returns the list_workshop_refunds projection" do
      workshop = WorkshopFixtures.workshop_fixture(status: "published")
      %{auth_user_id: member_id, principal_id: coordinator} = WorkshopFixtures.member_fixture()

      registration =
        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          member_user_id: member_id,
          status: "confirmed",
          amount_paid: 1800,
          display_name: "Ada Lovelace"
        )

      assert {:ok, view} =
               Workshops.refund_registration(
                 workshop.id,
                 registration.id,
                 "Unable to attend",
                 coordinator
               )

      assert [view] == Workshops.list_workshop_refunds(workshop.id)
      assert %{participant: %{type: :member, display_name: "Ada Lovelace"}} = view
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  # A BEFORE INSERT trigger that fails every insert on `table` as a unique
  # violation of `constraint`: a deterministic stand-in for a row committed by
  # a writer outside the lock. Created inside the sandbox, so it rolls back.
  defp force_unique_violation!(table, constraint) do
    Repo.query!("""
    CREATE FUNCTION ale340_force_unique_violation() RETURNS trigger AS $$
    BEGIN
      RAISE unique_violation USING CONSTRAINT = '#{constraint}';
    END $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER ale340_force_unique_violation BEFORE INSERT ON #{table}
    FOR EACH ROW EXECUTE FUNCTION ale340_force_unique_violation()
    """)
  end

  defp start_member_payment!(workshop, member_id, overrides \\ %{}) do
    {:ok, %{payment_intent_id: pi}} =
      Workshops.create_member_payment_intent(workshop.id, member_id, %{})

    put_payment_intent(pi, workshop, member_id, overrides)
    pi
  end

  defp put_payment_intent(pi, workshop, member_id, overrides \\ %{}) do
    StripeStub.put_object(
      :payment_intents,
      StripeStub.member_payment_intent(pi, workshop.id, member_id, overrides)
    )
  end

  defp complete_member(workshop, member_id, pi),
    do: PaymentCommands.execute({:member, member_id}, {:complete_member_payment, workshop.id, pi})

  defp attempt_for(pi), do: Repo.get_by!(PaymentAttempt, stripe_payment_intent_id: pi)

  defp refund_event(stripe_refund_id, status),
    do:
      PaymentCommands.execute(
        :system,
        {:apply_refund_update, %{"id" => stripe_refund_id, "status" => status}}
      )

  defp unresolved_refund(workshop, status, updated_at) do
    %{auth_user_id: member_id} = WorkshopFixtures.member_fixture()

    registration =
      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: member_id,
        status: "refunded",
        amount_paid: 1800,
        stripe_payment_intent_id: "pi_#{System.unique_integer([:positive])}"
      )

    stripe_refund_id = if status == "processing", do: "re_#{System.unique_integer([:positive])}"

    registration
    |> refund_in(status, stripe_refund_id: stripe_refund_id)
    |> Ecto.Changeset.change(updated_at: updated_at)
    |> Repo.update!()
  end

  defp record_retrievals do
    test_pid = self()

    StripeStub.put(:retrieve_refund, fn id ->
      send(test_pid, {:retrieved_refund, id})
      {:ok, %{"id" => id, "status" => "succeeded"}}
    end)
  end

  defp retrieved(acc \\ []) do
    receive do
      {:retrieved_refund, id} -> retrieved([id | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp refund_in(registration, status, attrs \\ []) do
    refund =
      WorkshopFixtures.refund_fixture(registration_id: registration.id, refund_amount: 1800)

    refund
    |> Ecto.Changeset.change(
      Keyword.merge(
        [
          status: status,
          stripe_refund_id: "re_#{refund.id}",
          stripe_payment_intent_id: registration.stripe_payment_intent_id
        ],
        attrs
      )
    )
    |> Repo.update!()
  end
end
