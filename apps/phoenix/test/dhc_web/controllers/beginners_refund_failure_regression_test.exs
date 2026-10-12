defmodule DhcWeb.BeginnersRefundFailureRegressionTest do
  use DhcWeb.ConnCase, async: true
  use Oban.Testing, repo: Dhc.Repo

  import Dhc.BeginnersWorkshopFixtures
  import Ecto.Query

  alias Dhc.BeginnersIntakeStripe, as: Stripe
  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.{Clock, IntakeRefund}
  alias Dhc.Repo
  alias Dhc.Stripe.Webhook

  @now ~U[2026-10-22 12:00:00.000000Z]
  @secret "whsec_test_signing_key_for_webhook_verification"

  defp execute(actor, command),
    do: BeginnersWorkshops.execute(actor, command, clock: Clock.fixed(@now))

  for new_payment? <- [false, true] do
    @new_payment new_payment?
    test "a delayed refund failure permits recovery with a new payment: #{@new_payment}" do
      coordinator = staff_fixture("beginners_coordinator")
      person = waiting_person_fixture(~U[2025-01-01 12:00:00Z])
      assert {:ok, _} = execute(:system, {:import_carried_fee, person.id, "Paid"})
      Stripe.stub_payment_intent("pi_delayed_failure")

      assert {:ok, _} =
               execute(
                 {:staff, coordinator},
                 {:link_carried_fee_payment, person.id,
                  %{"payment_intent_id" => "pi_delayed_failure"}}
               )

      assert {:ok, _} = execute({:staff, coordinator}, {:refund_carried_fee, person.id, %{}})

      # Fixture lookup supplies the identity needed to drive the public command;
      # outcomes are asserted through public views, not persistence rows.
      refund =
        Repo.one!(
          from(r in IntakeRefund, where: r.stripe_payment_intent_id == "pi_delayed_failure")
        )

      Stripe.stub_refund_create("succeeded")
      assert {:ok, %{outcome: :completed}} = execute(:system, {:submit_refund, refund.id})

      if @new_payment do
        workshop = scheduled_fixture(coordinator, %{"contact_from" => "2026-10-20"})

        assert {:ok, _} =
                 execute(
                   {:staff, coordinator},
                   {:fast_track, workshop.id, {:waitlist_entry, person.id}}
                 )

        intake =
          Repo.one!(
            from(i in Dhc.BeginnersWorkshops.Intake, where: i.workshop_id == ^workshop.id)
          )

        token = Dhc.BeginnersWorkshops.IntakeLink.token(intake.id, 1)
        Stripe.stub_create()
        assert {:ok, _} = execute({:intake_link, token}, :start_payment)

        payment =
          Repo.one!(
            from(p in Dhc.BeginnersWorkshops.IntakePayment, where: p.intake_id == ^intake.id)
          )

        assert {:ok, %{outcome: :paid}} =
                 execute(:stripe, {:complete_payment, Stripe.session(payment)})
      end

      object =
        Stripe.refund_object(refund.id, %{
          "status" => "failed",
          "failure_reason" => "expired_or_canceled_card"
        })

      payload = Jason.encode!(Stripe.event("refund.failed", object))

      assert build_conn()
             |> put_req_header("content-type", "application/json")
             |> put_req_header(
               "stripe-signature",
               Webhook.generate_test_signature(payload, @secret)
             )
             |> post("/api/webhooks/stripe", payload)
             |> json_response(200)

      assert %{success: successes, failure: 0} = Oban.drain_queue(queue: :stripe)
      assert successes >= 1

      assert {:ok, %{status: status, available: available, failed_refund: %{id: failed_id}}} =
               BeginnersWorkshops.carried_fee(person.id, clock: Clock.fixed(@now))

      assert status == if(@new_payment, do: "refunded", else: "held")
      assert failed_id == refund.id
      assert :retry in available
      assert :manual in available
      assert :forfeit in available == not @new_payment
      assert {:ok, %{notifications: notifications}} = Dhc.Notifications.list_for_user(coordinator)
      assert Enum.any?(notifications, &String.contains?(&1.body, "refund"))

      assert {:ok, %{status: "pending", follows_refund_id: follows}} =
               execute({:staff, coordinator}, {:retry_refund, {:person, person.id}, refund.id})

      assert follows == refund.id
    end
  end
end
