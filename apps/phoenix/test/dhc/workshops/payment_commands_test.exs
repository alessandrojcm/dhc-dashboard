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
      StripeStub.put(:create_refund, fn _ -> {:error, :timeout} end)

      assert {:error, :timeout} = PaymentCommands.execute(:system, {:submit_refund, refund.id})
      assert %{status: "pending", last_error: ":timeout"} = Repo.get!(Refund, refund.id)
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
            {{:member, id}, {:request_refund, id, id, "x", []}},
            {:system, {:cancel_workshop, id, & &1}},
            {{:coordinator, nil}, {:request_refund, id, id, "x", []}},
            {{:coordinator, id}, {:submit_refund, id}},
            {:external, :reconcile_refunds}
          ] do
        assert {:error, :forbidden} = PaymentCommands.execute(actor, command)
      end

      assert {:error, :unknown_command} = PaymentCommands.execute(:system, {:refund_everything})
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

      # Stands in for a Refund committed by a writer that bypassed the lock:
      # the insert fails on the registration_id unique index.
      Repo.query!("""
      CREATE FUNCTION ale340_duplicate_refund() RETURNS trigger AS $$
      BEGIN
        RAISE unique_violation USING CONSTRAINT = 'club_activity_refunds_registration_id_index';
      END $$ LANGUAGE plpgsql
      """)

      Repo.query!("""
      CREATE TRIGGER ale340_duplicate_refund BEFORE INSERT ON club_activity_refunds
      FOR EACH ROW EXECUTE FUNCTION ale340_duplicate_refund()
      """)

      assert {:error, :already_requested} = Workshops.cancel_workshop(workshop.id, coordinator)
      assert %{status: "published"} = Repo.get!(Workshop, workshop.id)
      assert %{status: "confirmed"} = Repo.get!(Registration, registration.id)
      assert all_enqueued(worker: Dhc.Workshops.Workers.RefundWorker) == []
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

      assert {:ok, %Refund{}} =
               Workshops.process_refund(workshop.id, registration.id, "Club", coordinator,
                 skip_eligibility: true
               )

      assert {:error, :already_refunded} = Workshops.refund_eligibility(registration.id)
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
