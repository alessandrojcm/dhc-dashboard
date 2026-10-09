defmodule Dhc.BeginnersWorkshops.RefundsTest do
  @moduledoc """
  ALE-382: automatic Intake refunds and the failed-refund follow-up, through
  `Dhc.BeginnersWorkshops.execute/3` with a fixed clock and Stripe stubbed at
  the HTTP seam (`Dhc.BeginnersIntakeStripe`) — the automatic refund of a
  `policy_failed` payment and of one completed after its Intake closed,
  `submit_refund`, `apply_refund_event`, `retry_refund`,
  `record_manual_refund`, `reconcile`, the refund transition table, the
  `refund.*` webhook routes and the console's refund status and Needs
  attention list.

  The workshop under test is `contacted_fixture/2`'s (fee €40).
  """

  use Dhc.DataCase, async: true
  use Oban.Testing, repo: Dhc.Repo

  import Dhc.BeginnersWorkshopFixtures

  alias Dhc.BeginnersIntakeStripe, as: Stripe
  alias Dhc.BeginnersWorkshops

  alias Dhc.BeginnersWorkshops.{
    Clock,
    Commands,
    Intake,
    IntakeEmailLog,
    IntakePayment,
    IntakeRefund
  }

  alias Dhc.BeginnersWorkshops.Workers.RefundWorker
  alias Dhc.Email.Worker
  alias Dhc.Notifications.Notification
  alias Dhc.Repo
  alias Dhc.StripeWebhooks

  @now ~U[2026-10-22 12:00:00.000000Z]
  @later ~U[2026-10-22 13:00:00.000000Z]

  setup do
    %{coordinator: staff_fixture("beginners_coordinator")}
  end

  defp at(at \\ @now), do: Clock.fixed(at)

  defp execute(actor, command, at \\ @now),
    do: BeginnersWorkshops.execute(actor, command, clock: at(at))

  defp pay!(token, intake) do
    Stripe.stub_create()
    assert {:ok, _} = execute({:intake_link, token}, :start_payment)
    Repo.one!(from(p in IntakePayment, where: p.intake_id == ^intake.id and p.status == "open"))
  end

  defp complete(session), do: execute(:stripe, {:complete_payment, session})

  defp refunds(intake),
    do:
      Repo.all(
        from(r in IntakeRefund,
          where: r.intake_id == ^intake.id,
          order_by: [asc: r.requested_at, asc: r.created_at]
        )
      )

  defp refund!(intake), do: intake |> refunds() |> List.last()

  # A payment whose amount failed the policy, with its automatic refund.
  defp policy_failed!(coordinator) do
    {workshop, [{intake, token}]} = contacted_fixture(coordinator, 1)
    payment = pay!(token, intake)

    assert {:ok, %{outcome: :policy_failed}} =
             complete(Stripe.session(payment, %{"amount_total" => 3500}))

    {workshop, intake, Repo.reload!(payment), refund!(intake)}
  end

  defp failed!(coordinator) do
    {workshop, intake, payment, refund} = policy_failed!(coordinator)
    Stripe.fail_refund_create(400)
    assert {:ok, %{outcome: :failed}} = execute(:system, {:submit_refund, refund.id})
    {workshop, intake, payment, Repo.reload!(refund)}
  end

  defp refunded_emails,
    do:
      Enum.filter(
        all_enqueued(worker: Worker),
        &(&1.args["transactional_id"] == "beginnersWorkshopNotice")
      )

  defp alerts(principal_id),
    do:
      Repo.all(
        from(n in Notification,
          where: n.principal_id == ^principal_id and like(n.notification_key, "%refund%")
        )
      )

  describe "the automatic refund" do
    test "a policy-failed payment is refunded in full against the payment and the person told",
         %{coordinator: coordinator} do
      {_workshop, intake, payment, refund} = policy_failed!(coordinator)

      assert %IntakeRefund{
               status: "pending",
               method: "stripe",
               reason: "policy_failed",
               amount_cents: 3500,
               currency: "eur"
             } = refund

      assert refund.payment_id == payment.id
      assert refund.stripe_payment_intent_id == "pi_#{payment.id}"
      assert refund.idempotency_key == "beginners-intake-refund:#{refund.id}"
      assert IntakeRefund.automatic?(refund)
      assert_enqueued(worker: RefundWorker, args: %{"refund_id" => refund.id})

      assert %Intake{state: "contacted"} = Repo.reload!(intake)

      assert [email] = refunded_emails()
      assert email.args["data_variables"]["MESSAGE_HTML"] =~ "€35.00"

      assert [%IntakeEmailLog{email_type: "payment_refunded"}] =
               Repo.all(from(l in IntakeEmailLog, where: l.occasion != "contact"))
    end

    test "a payment that completes after its Intake closed is recorded and refunded at once",
         %{coordinator: coordinator} do
      {_workshop, [{intake, token}]} = contacted_fixture(coordinator, 1)
      payment = pay!(token, intake)
      force_intake_state!(intake.id, "lapsed")

      assert {:ok, %{outcome: :paid_after_close}} = complete(Stripe.session(payment))

      assert %IntakePayment{status: "paid"} = Repo.reload!(payment)
      assert %Intake{state: "lapsed"} = Repo.reload!(intake)

      assert [%IntakeRefund{reason: "paid_after_close", amount_cents: 4000, status: "pending"}] =
               refunds(intake)

      assert [_payment_refunded] = refunded_emails()
    end

    test "completing the same session again requests no second refund",
         %{coordinator: coordinator} do
      {_workshop, intake, payment, _refund} = policy_failed!(coordinator)

      assert {:ok, %{outcome: :already_recorded}} =
               complete(Stripe.session(payment, %{"amount_total" => 3500}))

      assert [_one] = refunds(intake)
      assert [_one_email] = refunded_emails()
    end
  end

  describe "submit_refund" do
    test "refunds the PaymentIntent under the refund's key and records Stripe's answer",
         %{coordinator: coordinator} do
      {_workshop, _intake, payment, refund} = policy_failed!(coordinator)
      Stripe.stub_refund_create("succeeded")

      assert {:ok, %{outcome: :completed}} =
               execute(:system, {:submit_refund, refund.id}, @later)

      assert_received {:refund_created, form, key}
      assert key == "beginners-intake-refund:#{refund.id}"

      assert %{
               "payment_intent" => payment_intent,
               "amount" => "3500",
               "metadata[refund_id]" => refund_id
             } = form

      assert payment_intent == "pi_#{payment.id}"
      assert refund_id == refund.id

      assert %IntakeRefund{status: "completed", completed_at: @later} =
               refund = Repo.reload!(refund)

      assert refund.stripe_refund_id == Stripe.stripe_refund_id(refund)

      # Already answered: nothing is sent again.
      assert {:ok, %{outcome: :already_submitted}} =
               execute(:system, {:submit_refund, refund.id})

      refute_received {:refund_created, _form, _key}
    end

    test "Stripe accepting a refund leaves it processing until its event",
         %{coordinator: coordinator} do
      {_workshop, _intake, _payment, refund} = policy_failed!(coordinator)
      Stripe.stub_refund_create("pending")

      assert {:ok, %{outcome: :processing}} = execute(:system, {:submit_refund, refund.id})
      assert %IntakeRefund{status: "processing"} = Repo.reload!(refund)
    end

    test "a Stripe outage keeps the refund pending and fails so the job retries",
         %{coordinator: coordinator} do
      {_workshop, _intake, _payment, refund} = policy_failed!(coordinator)
      Stripe.fail_refund_create(500)

      assert {:error, :stripe_unavailable} = execute(:system, {:submit_refund, refund.id})
      assert %IntakeRefund{status: "pending", last_error: error} = Repo.reload!(refund)
      assert is_binary(error)
    end

    test "a refund Stripe refuses fails, alerts the coordinators and emails nobody",
         %{coordinator: coordinator} do
      emails_before = length(refunded_emails())
      {_workshop, _intake, _payment, refund} = failed!(coordinator)

      assert %IntakeRefund{status: "failed", failed_at: @now} = refund
      assert [alert] = alerts(coordinator)
      assert alert.notification_key == "beginners-workshop-refund:#{refund.id}:failed"
      assert alert.body =~ "€35.00"
      assert length(refunded_emails()) == emails_before + 1
    end

    test "an unknown refund is not found; only the system may submit",
         %{coordinator: coordinator} do
      assert {:error, :refund_not_found} =
               execute(:system, {:submit_refund, Ecto.UUID.generate()})

      assert {:error, :refund_not_found} = execute(:system, {:submit_refund, "nope"})

      assert {:error, :forbidden} =
               execute({:staff, coordinator}, {:submit_refund, Ecto.UUID.generate()})
    end
  end

  describe "apply_refund_event" do
    test "settles a processing refund; a terminal refund ignores later events",
         %{coordinator: coordinator} do
      {_workshop, _intake, _payment, refund} = policy_failed!(coordinator)
      Stripe.stub_refund_create("pending")
      assert {:ok, _} = execute(:system, {:submit_refund, refund.id})

      assert {:ok, %{outcome: :completed}} =
               execute(:stripe, {:apply_refund_event, Stripe.refund_object(refund.id)})

      assert {:ok, %{outcome: :already_settled}} =
               execute(
                 :stripe,
                 {:apply_refund_event, Stripe.refund_object(refund.id, %{"status" => "failed"})}
               )

      assert %IntakeRefund{status: "completed"} = Repo.reload!(refund)
      assert alerts(coordinator) == []
    end

    test "finds a refund by its metadata when the event beats the submission's record",
         %{coordinator: coordinator} do
      {_workshop, _intake, _payment, refund} = policy_failed!(coordinator)

      assert {:ok, %{outcome: :completed}} =
               execute(:stripe, {:apply_refund_event, Stripe.refund_object(refund.id)})

      assert %IntakeRefund{status: "completed"} = refund = Repo.reload!(refund)
      assert refund.stripe_refund_id == Stripe.stripe_refund_id(refund)
    end

    test "a failed event fails the refund and notifies once however often it arrives",
         %{coordinator: coordinator} do
      {_workshop, _intake, _payment, refund} = policy_failed!(coordinator)
      failed = Stripe.refund_object(refund.id, %{"status" => "failed"})

      assert {:ok, %{outcome: :failed}} = execute(:stripe, {:apply_refund_event, failed})
      assert {:ok, %{outcome: :already_settled}} = execute(:stripe, {:apply_refund_event, failed})

      assert %IntakeRefund{status: "failed"} = Repo.reload!(refund)
      assert [_one] = alerts(coordinator)
    end

    test "a refund that is not ours is acknowledged without effect" do
      assert {:ok, %{outcome: :not_ours}} =
               execute(
                 :stripe,
                 {:apply_refund_event, %{"id" => "re_workshop", "status" => "succeeded"}}
               )
    end
  end

  describe "refund.* webhooks" do
    test "call the Workshops target and the Beginners' Workshop target; each ignores the other's",
         %{coordinator: coordinator} do
      {_workshop, _intake, _payment, refund} = policy_failed!(coordinator)

      for type <- ~w(refund.created refund.updated refund.failed),
          do:
            assert(
              StripeWebhooks.routes()[type]
              |> Enum.member?({:beginners_intake, :apply_refund_event})
            )

      assert :ok =
               StripeWebhooks.process_event(
                 Stripe.event("refund.updated", Stripe.refund_object(refund.id))
               )

      assert %IntakeRefund{status: "completed"} = Repo.reload!(refund)

      # A Workshop refund (no Intake metadata) reaches the Beginners' target
      # too, which acknowledges it.
      assert :ok =
               StripeWebhooks.process_event(
                 Stripe.event("refund.updated", %{
                   "id" => "re_workshop",
                   "status" => "succeeded",
                   "metadata" => %{}
                 })
               )
    end
  end

  describe "retry_refund" do
    test "creates a new refund and key against the same payment and keeps the failed row",
         %{coordinator: coordinator} do
      {workshop, intake, payment, failed} = failed!(coordinator)
      emails = length(refunded_emails())

      assert {:ok, %{status: "pending", follows_refund_id: follows} = view} =
               execute({:staff, coordinator}, {:retry_refund, workshop.id, failed.id}, @later)

      assert follows == failed.id
      retry = Repo.get!(IntakeRefund, view.id)
      assert retry.payment_id == payment.id
      assert retry.amount_cents == failed.amount_cents
      assert retry.idempotency_key == "beginners-intake-refund:#{retry.id}"
      refute retry.idempotency_key == failed.idempotency_key
      assert retry.requested_by_principal_id == coordinator
      assert_enqueued(worker: RefundWorker, args: %{"refund_id" => retry.id})

      assert %IntakeRefund{status: "failed"} = Repo.reload!(failed)
      assert [_failed, _retry] = refunds(intake)
      assert length(refunded_emails()) == emails

      Stripe.stub_refund_create("succeeded")
      assert {:ok, %{outcome: :completed}} = execute(:system, {:submit_refund, retry.id})
      assert_received {:refund_created, _form, key}
      assert key == retry.idempotency_key
    end

    test "is refused for a refund that has not failed, was followed up, or is elsewhere",
         %{coordinator: coordinator} do
      {workshop, _intake, _payment, failed} = failed!(coordinator)

      assert {:ok, %{id: retry_id}} =
               execute({:staff, coordinator}, {:retry_refund, workshop.id, failed.id})

      assert {:error, :refund_followed_up} =
               execute({:staff, coordinator}, {:retry_refund, workshop.id, failed.id})

      assert {:error, :refund_not_failed} =
               execute({:staff, coordinator}, {:retry_refund, workshop.id, retry_id})

      other = scheduled_fixture(coordinator)

      assert {:error, :refund_not_found} =
               execute({:staff, coordinator}, {:retry_refund, other.id, failed.id})

      assert {:error, :forbidden} =
               execute({:staff, staff_fixture("coach")}, {:retry_refund, workshop.id, failed.id})
    end
  end

  describe "record_manual_refund" do
    test "records a completed manual refund, emails nobody, and closes the follow-up",
         %{coordinator: coordinator} do
      {workshop, intake, _payment, failed} = failed!(coordinator)
      emails = length(refunded_emails())

      assert {:ok, %{status: "completed", method: "manual", follows_refund_id: follows}} =
               execute(
                 {:staff, coordinator},
                 {:record_manual_refund, workshop.id, failed.id, %{"note" => " Revolut "}},
                 @later
               )

      assert follows == failed.id

      assert %IntakeRefund{method: "manual", note: "Revolut", completed_at: @later} =
               refund!(intake)

      assert %IntakeRefund{status: "failed"} = Repo.reload!(failed)
      assert length(refunded_emails()) == emails

      assert {:error, :refund_followed_up} =
               execute({:staff, coordinator}, {:retry_refund, workshop.id, failed.id})

      assert {:error, :invalid_payload} =
               execute(
                 {:staff, coordinator},
                 {:record_manual_refund, workshop.id, failed.id, %{"note" => 5}}
               )
    end
  end

  describe "reconcile" do
    test "enqueues pending refunds and settles processing ones from Stripe",
         %{coordinator: coordinator} do
      {_workshop, _intake, _payment, pending} = policy_failed!(coordinator)
      {_workshop, _intake, _payment, processing} = policy_failed!(coordinator)
      Stripe.stub_refund_create("pending")
      assert {:ok, %{outcome: :processing}} = execute(:system, {:submit_refund, processing.id})
      Stripe.stub_refund_retrieve(Stripe.refund_object(processing.id))

      assert {:ok, %{refunds_resubmitted: 1, refunds_settled: 1}} =
               execute(:system, :reconcile)

      assert_enqueued(worker: RefundWorker, args: %{"refund_id" => pending.id})
      assert %IntakeRefund{status: "completed"} = Repo.reload!(processing)
    end

    test "repairs a missed checkout.session.completed for a live hold",
         %{coordinator: coordinator} do
      {_workshop, [{intake, token}]} = contacted_fixture(coordinator, 1)
      payment = pay!(token, intake)
      Stripe.stub_retrieve(Stripe.session(payment))

      assert {:ok, %{payments_settled: 1}} = execute(:system, :reconcile)
      assert %Intake{state: "paid"} = Repo.reload!(intake)
    end

    test "only the system may reconcile", %{coordinator: coordinator} do
      assert {:error, :forbidden} = execute({:staff, coordinator}, :reconcile)
      assert {:ok, %{refunds_resubmitted: 0}} = execute(:system, :reconcile)
    end
  end

  describe "the console" do
    test "shows each Intake's refund and lists failed refunds under Needs attention",
         %{coordinator: coordinator} do
      {workshop, intake, _payment, failed} = failed!(coordinator)

      {:ok, console} = BeginnersWorkshops.workshop_console(workshop.id, clock: at())
      [row] = console.roster.asked
      assert row.id == intake.id
      assert %{status: "failed", method: "stripe", automatic: true} = row.refund

      assert [%{id: failed_id, amount_cents: 3500, reason: "policy_failed"}] =
               console.failed_refunds

      assert failed_id == failed.id

      assert {:ok, _} =
               execute(
                 {:staff, coordinator},
                 {:record_manual_refund, workshop.id, failed.id, %{}}
               )

      {:ok, console} = BeginnersWorkshops.workshop_console(workshop.id, clock: at())
      assert [%{refund: %{status: "completed", method: "manual"}}] = console.roster.asked
      assert console.failed_refunds == []
    end
  end

  describe "the transition table" do
    test "declares the refund moves; completed and failed are terminal" do
      assert Commands.transitions().refund == %{
               "pending" => ~w(processing completed failed),
               "processing" => ~w(completed failed)
             }

      for from <- ~w(completed failed),
          to <- IntakeRefund.statuses(),
          do: refute(Commands.transition_allowed?(:refund, from, to))

      refute Commands.transition_allowed?(:refund, "processing", "pending")
    end
  end
end
