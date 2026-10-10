defmodule Dhc.BeginnersWorkshops.Workers.RefundWorkersTest do
  @moduledoc """
  ALE-382: wiring of the Intake refund workers. The refund rules are proven
  in `Dhc.BeginnersWorkshops.RefundsTest`; this checks each worker turns its
  arguments into its command and maps the outcome to a job result.
  """

  use Dhc.DataCase, async: true
  use Oban.Testing, repo: Dhc.Repo

  import Dhc.BeginnersWorkshopFixtures

  alias Dhc.BeginnersIntakeStripe, as: Stripe
  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.{Clock, IntakePayment, IntakeRefund}
  alias Dhc.BeginnersWorkshops.Workers.{ReconcileWorker, RefundWorker}
  alias Dhc.Repo

  @now ~U[2026-10-22 12:00:00.000000Z]

  defp pending_refund! do
    {_workshop, [{intake, token}]} = contacted_fixture(staff_fixture(), 1)
    Stripe.stub_create()

    {:ok, _} =
      BeginnersWorkshops.execute({:intake_link, token}, :start_payment, clock: Clock.fixed(@now))

    payment = Repo.one!(from(p in IntakePayment, where: p.intake_id == ^intake.id))

    {:ok, %{outcome: :policy_failed}} =
      BeginnersWorkshops.execute(
        :stripe,
        {:complete_payment, Stripe.session(payment, %{"amount_total" => 100})},
        clock: Clock.fixed(@now)
      )

    Repo.one!(from(r in IntakeRefund, where: r.payment_id == ^payment.id))
  end

  describe "RefundWorker" do
    test "submits the refund named by its args" do
      refund = pending_refund!()
      Stripe.stub_refund_create("succeeded")

      assert :ok = perform_job(RefundWorker, %{"refund_id" => refund.id})
      assert %IntakeRefund{status: "completed"} = Repo.reload!(refund)
    end

    test "retries a Stripe outage and discards an unknown refund or bad args" do
      refund = pending_refund!()
      Stripe.fail_refund_create(500)

      assert {:error, :stripe_unavailable} =
               perform_job(RefundWorker, %{"refund_id" => refund.id})

      assert {:discard, :refund_not_found} =
               perform_job(RefundWorker, %{"refund_id" => Ecto.UUID.generate()})

      assert {:discard, :invalid_args} = perform_job(RefundWorker, %{})
    end

    test "a refusal is recorded as failed and the job succeeds" do
      refund = pending_refund!()
      Stripe.fail_refund_create(400)

      assert :ok = perform_job(RefundWorker, %{"refund_id" => refund.id})
      assert %IntakeRefund{status: "failed"} = Repo.reload!(refund)
    end
  end

  describe "ReconcileWorker" do
    test "runs one reconcile pass" do
      refund = pending_refund!()
      Repo.delete_all(Oban.Job)

      assert :ok = perform_job(ReconcileWorker, %{})
      assert_enqueued(worker: RefundWorker, args: %{"refund_id" => refund.id})
    end
  end
end
