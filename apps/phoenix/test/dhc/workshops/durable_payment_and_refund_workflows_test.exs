defmodule Dhc.Workshops.DurablePaymentAndRefundWorkflowsTest do
  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  alias Dhc.Repo
  alias Dhc.Workshops
  alias Dhc.Workshops.{PaymentAttempt, Refund, Registration}
  alias Dhc.Workshops.Workers.RefundWorker
  alias Dhc.Workshops.Workers.RefundReconciliationWorker
  alias Dhc.WorkshopFixtures

  defmodule StripeAdapter do
    @behaviour Dhc.Workshops.StripeAdapter

    def create_payment_intent(params) do
      send(test_pid(), {:create_payment_intent, params})

      {:ok,
       %{
         "id" => "pi_durable_member",
         "client_secret" => "pi_durable_member_secret",
         "amount" => params.amount,
         "currency" => params.currency,
         "status" => "requires_payment_method",
         "metadata" => %{}
       }}
    end

    def retrieve_payment_intent("pi_durable_member") do
      if Application.get_env(:dhc, :durable_payment_completed, false) do
        retrieve_payment_intent_completed("pi_durable_member")
      else
        {:ok,
         %{
           "id" => "pi_durable_member",
           "client_secret" => "pi_durable_member_secret",
           "amount" => 1800,
           "currency" => "eur",
           "status" => "requires_payment_method",
           "metadata" => %{}
         }}
      end
    end

    def retrieve_payment_intent(id) do
      retrieve_payment_intent_completed(id)
    end

    defp retrieve_payment_intent_completed(id) do
      {:ok,
       %{
         "id" => id,
         "amount" => 1800,
         "currency" => "eur",
         "status" => "succeeded",
         "metadata" => %{
           "type" => "workshop_registration",
           "actor_type" => "member",
           "workshop_id" => Application.fetch_env!(:dhc, :durable_test_workshop_id),
           "user_id" => Application.fetch_env!(:dhc, :durable_test_member_id)
         }
       }}
    end

    def create_checkout_session(params) do
      send(test_pid(), {:create_checkout_session, params})

      Application.put_env(
        :dhc,
        :durable_test_payment_attempt_id,
        params.body[:"metadata[payment_attempt_id]"]
      )

      {:ok,
       %{
         "id" => "cs_durable_external",
         "client_secret" => "cs_durable_external_secret",
         "url" => nil
       }}
    end

    def retrieve_checkout_session(id) do
      metadata = %{
        "type" => "workshop_registration",
        "actor_type" => "external",
        "workshop_id" => Application.fetch_env!(:dhc, :durable_test_workshop_id),
        "payment_attempt_id" => Application.fetch_env!(:dhc, :durable_test_payment_attempt_id)
      }

      metadata =
        if Application.get_env(:dhc, :durable_omit_payment_attempt_id, false) do
          Map.delete(metadata, "payment_attempt_id")
        else
          metadata
        end

      {:ok,
       %{
         "id" => id,
         "client_secret" => "cs_durable_external_secret",
         "status" => "complete",
         "payment_status" => "paid",
         "amount_total" => 2400,
         "currency" => "eur",
         "payment_intent" => "pi_durable_external",
         "metadata" => metadata,
         "customer_details" => %{
           "email" => "guest@example.com",
           "name" => "Grace Hopper",
           "phone" => "+353123456"
         }
       }}
    end

    def update_payment_intent(_id, _params), do: :ok

    def create_refund(params) do
      send(test_pid(), {:create_refund, params})

      Application.get_env(
        :dhc,
        :durable_refund_response,
        {:ok, %{"id" => "re_durable", "status" => "pending"}}
      )
    end

    def retrieve_refund(id) do
      case Application.get_env(:dhc, :durable_refund_retrieve_response) do
        nil -> {:ok, %{"id" => id, "status" => "succeeded"}}
        responses when is_map(responses) -> Map.fetch!(responses, id)
        response -> {:ok, response}
      end
    end

    defp test_pid, do: Application.fetch_env!(:dhc, :durable_workflow_test_pid)
  end

  setup do
    previous_adapter = Application.get_env(:dhc, :workshop_stripe_adapter)
    Application.put_env(:dhc, :workshop_stripe_adapter, StripeAdapter)
    Application.put_env(:dhc, :durable_workflow_test_pid, self())

    on_exit(fn ->
      Application.put_env(:dhc, :workshop_stripe_adapter, previous_adapter)
      Application.delete_env(:dhc, :durable_workflow_test_pid)
      Application.delete_env(:dhc, :durable_test_workshop_id)
      Application.delete_env(:dhc, :durable_test_member_id)
      Application.delete_env(:dhc, :durable_test_payment_attempt_id)
      Application.delete_env(:dhc, :durable_payment_completed)
      Application.delete_env(:dhc, :durable_refund_response)
      Application.delete_env(:dhc, :durable_refund_retrieve_response)
      Application.delete_env(:dhc, :durable_omit_payment_attempt_id)
    end)

    :ok
  end

  describe "member Payment Attempts" do
    test "uses the Workshop price and replays the same durable attempt" do
      workshop =
        WorkshopFixtures.workshop_fixture(
          status: "published",
          price_member: 1800.0,
          max_capacity: 2
        )

      %{auth_user_id: member_id} = WorkshopFixtures.member_fixture()

      assert {:ok, first} =
               Workshops.create_member_payment_intent(workshop.id, member_id, %{
                 amount: 1,
                 currency: "usd"
               })

      assert first == %{
               client_secret: "pi_durable_member_secret",
               payment_intent_id: "pi_durable_member"
             }

      assert_receive {:create_payment_intent,
                      %{
                        amount: 1800,
                        currency: "eur",
                        workshop_id: workshop_id,
                        user_id: ^member_id
                      }}

      assert workshop_id == workshop.id

      assert %PaymentAttempt{
               club_activity_id: attempt_workshop_id,
               member_user_id: ^member_id,
               amount: 1800,
               currency: "eur",
               stripe_payment_intent_id: "pi_durable_member",
               status: "pending"
             } = Repo.get_by!(PaymentAttempt, stripe_payment_intent_id: "pi_durable_member")

      assert attempt_workshop_id == workshop.id

      assert {:ok, ^first} =
               Workshops.create_member_payment_intent(workshop.id, member_id, %{amount: 9999})

      refute_receive {:create_payment_intent, _}
      assert Repo.aggregate(PaymentAttempt, :count) == 1
    end

    test "concludes a paid attempt exactly once with its Registration" do
      workshop =
        WorkshopFixtures.workshop_fixture(
          status: "published",
          price_member: 1800.0,
          max_capacity: 2
        )

      %{auth_user_id: member_id} = WorkshopFixtures.member_fixture()
      Application.put_env(:dhc, :durable_test_workshop_id, workshop.id)
      Application.put_env(:dhc, :durable_test_member_id, member_id)

      assert {:ok, %{payment_intent_id: payment_intent_id}} =
               Workshops.create_member_payment_intent(workshop.id, member_id, %{})

      Application.put_env(:dhc, :durable_payment_completed, true)

      assert {:ok, registration} =
               Workshops.complete_member_registration(workshop.id, member_id, payment_intent_id)

      assert registration.amount_paid == 1800
      assert registration.payment_attempt_id

      assert %PaymentAttempt{status: "registered", concluded_at: %DateTime{}} =
               Repo.get!(PaymentAttempt, registration.payment_attempt_id)

      assert {:ok, replay} =
               Workshops.complete_member_registration(workshop.id, member_id, payment_intent_id)

      assert replay.id == registration.id
    end

    test "durably compensates a valid payment that loses the capacity race" do
      workshop =
        WorkshopFixtures.workshop_fixture(
          status: "published",
          price_member: 1800.0,
          max_capacity: 1
        )

      %{auth_user_id: member_id} = WorkshopFixtures.member_fixture()
      Application.put_env(:dhc, :durable_test_workshop_id, workshop.id)
      Application.put_env(:dhc, :durable_test_member_id, member_id)

      assert {:ok, %{payment_intent_id: payment_intent_id}} =
               Workshops.create_member_payment_intent(workshop.id, member_id, %{})

      %{auth_user_id: other_member_id} = WorkshopFixtures.member_fixture()

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: other_member_id,
        status: "confirmed"
      )

      Application.put_env(:dhc, :durable_payment_completed, true)

      assert {:error, :compensation_pending} =
               Workshops.complete_member_registration(workshop.id, member_id, payment_intent_id)

      attempt = Repo.get_by!(PaymentAttempt, stripe_payment_intent_id: payment_intent_id)

      assert %{payment_attempt_id: attempt_id, registration_id: nil, status: "pending"} =
               refund = Repo.get_by!(Refund, payment_attempt_id: attempt.id)

      assert attempt_id == attempt.id
      assert Repo.reload!(attempt).status == "compensating"

      assert_enqueued(
        worker: RefundWorker,
        args: %{refund_id: Repo.get_by!(Refund, payment_attempt_id: attempt.id).id}
      )

      refute_receive {:create_refund, _}

      assert {:error, :compensation_pending} =
               Workshops.complete_member_registration(workshop.id, member_id, payment_intent_id)

      assert Repo.aggregate(Refund, :count, :id) == 1
      assert length(all_enqueued(worker: RefundWorker)) == 1

      Application.put_env(
        :dhc,
        :durable_refund_response,
        {:ok, %{"id" => "re_immediate_success", "status" => "succeeded"}}
      )

      assert :ok = perform_job(RefundWorker, %{refund_id: refund.id})
      assert %{status: "completed"} = Repo.get!(Refund, refund.id)
      assert %{status: "refunded"} = Repo.get!(PaymentAttempt, attempt.id)
    end
  end

  describe "external Payment Attempts" do
    test "persists the attempt before creating Checkout with stable idempotency" do
      workshop =
        WorkshopFixtures.workshop_fixture(
          status: "published",
          is_public: true,
          price_non_member: 2400.0,
          max_capacity: 1
        )

      return_url = "https://example.com/confirmation?session_id={CHECKOUT_SESSION_ID}"
      payment_attempt_id = Ecto.UUID.generate()
      Application.put_env(:dhc, :durable_test_workshop_id, workshop.id)

      assert {:ok, %{checkout_session_id: "cs_durable_external"}} =
               Workshops.create_external_checkout_session(
                 workshop.id,
                 payment_attempt_id,
                 return_url
               )

      assert %PaymentAttempt{
               club_activity_id: workshop_id,
               actor_type: "external",
               amount: 2400,
               currency: "eur",
               status: "pending",
               stripe_checkout_session_id: "cs_durable_external"
             } =
               attempt =
               Repo.get_by!(PaymentAttempt, stripe_checkout_session_id: "cs_durable_external")

      assert workshop_id == workshop.id

      assert_receive {:create_checkout_session,
                      %{
                        idempotency_key: idempotency_key,
                        body: body
                      }}

      assert idempotency_key == "workshop-payment-attempt:#{attempt.id}"
      assert body[:"line_items[0][price_data][unit_amount]"] == 2400
      assert body[:"metadata[payment_attempt_id]"] == attempt.id

      %{auth_user_id: member_id} = WorkshopFixtures.member_fixture()

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: member_id,
        status: "confirmed"
      )

      assert {:ok, %{checkout_session_id: "cs_durable_external"}} =
               Workshops.create_external_checkout_session(
                 workshop.id,
                 payment_attempt_id,
                 return_url
               )

      refute_receive {:create_checkout_session, _}
      assert Repo.aggregate(PaymentAttempt, :count) == 1
    end

    test "durably compensates a paid Checkout that loses the capacity race" do
      workshop =
        WorkshopFixtures.workshop_fixture(
          status: "published",
          is_public: true,
          price_non_member: 2400.0,
          max_capacity: 1
        )

      Application.put_env(:dhc, :durable_test_workshop_id, workshop.id)
      return_url = "https://example.com/confirmation?session_id={CHECKOUT_SESSION_ID}"

      assert {:ok, %{checkout_session_id: checkout_session_id}} =
               Workshops.create_external_checkout_session(
                 workshop.id,
                 Ecto.UUID.generate(),
                 return_url
               )

      %{auth_user_id: member_id} = WorkshopFixtures.member_fixture()

      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: member_id,
        status: "confirmed"
      )

      assert {:error, :compensation_pending} =
               Workshops.complete_external_registration(workshop.id, checkout_session_id)

      attempt = Repo.get_by!(PaymentAttempt, stripe_checkout_session_id: checkout_session_id)

      assert %Refund{
               registration_id: nil,
               payment_attempt_id: attempt_id,
               stripe_payment_intent_id: "pi_durable_external",
               status: "pending"
             } = refund = Repo.get_by!(Refund, payment_attempt_id: attempt.id)

      assert attempt_id == attempt.id
      assert Repo.reload!(attempt).status == "compensating"
      assert_enqueued(worker: RefundWorker, args: %{refund_id: refund.id})
      refute_receive {:create_refund, _}

      assert {:error, :compensation_pending} =
               Workshops.complete_external_registration(workshop.id, checkout_session_id)

      assert Repo.aggregate(Refund, :count, :id) == 1
      assert length(all_enqueued(worker: RefundWorker)) == 1
    end

    test "rejects a paid Checkout without its durable Payment Attempt identity" do
      workshop =
        WorkshopFixtures.workshop_fixture(
          status: "published",
          is_public: true,
          price_non_member: 2400.0
        )

      Application.put_env(:dhc, :durable_test_workshop_id, workshop.id)
      return_url = "https://example.com/confirmation?session_id={CHECKOUT_SESSION_ID}"

      assert {:ok, %{checkout_session_id: checkout_session_id}} =
               Workshops.create_external_checkout_session(
                 workshop.id,
                 Ecto.UUID.generate(),
                 return_url
               )

      Application.put_env(:dhc, :durable_omit_payment_attempt_id, true)

      assert {:error, :payment_metadata_mismatch} =
               Workshops.complete_external_registration(workshop.id, checkout_session_id)

      assert Repo.aggregate(Registration, :count, :id) == 0
      assert Repo.aggregate(Refund, :count, :id) == 0
    end

    test "a Workshop with an unconcluded Payment Attempt is archived instead of deleted" do
      workshop =
        WorkshopFixtures.workshop_fixture(
          status: "published",
          is_public: true,
          price_non_member: 2400.0
        )

      return_url = "https://example.com/confirmation?session_id={CHECKOUT_SESSION_ID}"

      assert {:ok, _result} =
               Workshops.create_external_checkout_session(
                 workshop.id,
                 Ecto.UUID.generate(),
                 return_url
               )

      assert {:ok, :archived, _summary} = Workshops.delete_workshop(workshop.id)
      assert Repo.get!(Dhc.Workshops.Workshop, workshop.id).archived_at
    end
  end

  describe "durable Refund obligations" do
    test "records the Refund and one job atomically without calling Stripe" do
      workshop =
        WorkshopFixtures.workshop_fixture(
          status: "published",
          start_date: DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:second)
        )

      %{auth_user_id: member_id, principal_id: requested_by} =
        WorkshopFixtures.member_fixture()

      registration =
        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          member_user_id: member_id,
          status: "confirmed",
          amount_paid: 1800,
          stripe_payment_intent_id: "pi_refund_durable"
        )

      assert {:ok, %Refund{status: "pending"} = refund} =
               Workshops.process_refund(
                 workshop.id,
                 registration.id,
                 "Unable to attend",
                 requested_by
               )

      assert refund.idempotency_key == "workshop-refund:#{refund.id}"
      assert %{status: "refunded"} = Repo.get!(Registration, registration.id)

      assert_enqueued(worker: RefundWorker, args: %{refund_id: refund.id})
      assert [_job] = all_enqueued(worker: RefundWorker)
      refute_receive {:create_refund, _}
    end

    test "the worker uses stable idempotency and retries provider failures" do
      {refund, _registration} = durable_refund_fixture()
      payment_intent_id = refund.stripe_payment_intent_id

      Application.put_env(:dhc, :durable_refund_response, {:error, :provider_unavailable})

      assert {:error, :provider_unavailable} =
               perform_job(RefundWorker, %{refund_id: refund.id})

      assert_receive {:create_refund,
                      %{
                        body: [
                          payment_intent: ^payment_intent_id,
                          amount: 1800,
                          reason: "requested_by_customer"
                        ],
                        idempotency_key: idempotency_key
                      }}

      assert idempotency_key == refund.idempotency_key
      assert %{status: "pending", last_error: last_error} = Repo.get!(Refund, refund.id)
      assert last_error =~ "provider_unavailable"

      Application.put_env(
        :dhc,
        :durable_refund_response,
        {:error, {:stripe_api, 429, "rate limited"}}
      )

      assert {:error, {:stripe_api, 429, "rate limited"}} =
               perform_job(RefundWorker, %{refund_id: refund.id})

      assert %{status: "pending"} = Repo.get!(Refund, refund.id)

      Application.delete_env(:dhc, :durable_refund_response)

      assert :ok = perform_job(RefundWorker, %{refund_id: refund.id})

      assert %{status: "processing", stripe_refund_id: "re_durable"} =
               Repo.get!(Refund, refund.id)
    end

    test "Stripe events and reconciliation drive terminal progression idempotently" do
      {refund, _registration} = durable_refund_fixture()
      assert :ok = perform_job(RefundWorker, %{refund_id: refund.id})

      event = %{
        "type" => "refund.updated",
        "data" => %{"object" => %{"id" => "re_durable", "status" => "succeeded"}}
      }

      assert :ok = Dhc.StripeWebhooks.process_event(event)
      assert :ok = Dhc.StripeWebhooks.process_event(event)
      assert %{status: "completed", completed_at: %DateTime{}} = Repo.get!(Refund, refund.id)

      assert :ok =
               Dhc.StripeWebhooks.process_event(%{
                 "type" => "refund.updated",
                 "data" => %{"object" => %{"id" => "re_durable", "status" => "pending"}}
               })

      assert %{status: "completed", completed_at: %DateTime{}} = Repo.get!(Refund, refund.id)

      second_refund =
        durable_refund_fixture()
        |> elem(0)

      Application.put_env(
        :dhc,
        :durable_refund_response,
        {:ok, %{"id" => "re_durable_second", "status" => "pending"}}
      )

      assert :ok = perform_job(RefundWorker, %{refund_id: second_refund.id})
      assert :ok = perform_job(RefundReconciliationWorker, %{})

      assert %{status: "completed", completed_at: %DateTime{}} =
               Repo.get!(Refund, second_refund.id)
    end

    test "reconciliation continues after an individual provider failure" do
      first_refund = durable_refund_fixture() |> elem(0)
      second_refund = durable_refund_fixture() |> elem(0)

      Application.put_env(
        :dhc,
        :durable_refund_response,
        {:ok, %{"id" => "re_reconcile_first", "status" => "pending"}}
      )

      assert :ok = perform_job(RefundWorker, %{refund_id: first_refund.id})

      Application.put_env(
        :dhc,
        :durable_refund_response,
        {:ok, %{"id" => "re_reconcile_second", "status" => "pending"}}
      )

      assert :ok = perform_job(RefundWorker, %{refund_id: second_refund.id})

      Application.put_env(:dhc, :durable_refund_retrieve_response, %{
        "re_reconcile_first" => {:error, :provider_unavailable},
        "re_reconcile_second" => {:ok, %{"id" => "re_reconcile_second", "status" => "succeeded"}}
      })

      assert {:error, :provider_unavailable} =
               perform_job(RefundReconciliationWorker, %{})

      assert %{status: "processing"} = Repo.get!(Refund, first_refund.id)
      assert %{status: "completed"} = Repo.get!(Refund, second_refund.id)
    end
  end

  defp durable_refund_fixture do
    payment_intent_id = "pi_worker_refund_#{System.unique_integer([:positive])}"

    workshop =
      WorkshopFixtures.workshop_fixture(
        status: "published",
        start_date: DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:second)
      )

    %{auth_user_id: member_id, principal_id: requested_by} = WorkshopFixtures.member_fixture()

    registration =
      WorkshopFixtures.registration_fixture(
        workshop_id: workshop.id,
        member_user_id: member_id,
        status: "confirmed",
        amount_paid: 1800,
        stripe_payment_intent_id: payment_intent_id
      )

    {:ok, refund} =
      Workshops.process_refund(workshop.id, registration.id, "Unable to attend", requested_by)

    {refund, registration}
  end
end
