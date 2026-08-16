defmodule Dhc.Workshops.StripeIdentifierWriteTest do
  @moduledoc """
  ALE-193 (code release): after the ALE-179 expand migration split the
  Stripe identifier into `stripe_payment_intent_id` (`pi_*`) and
  `stripe_checkout_session_id` (`cs_*`), the application must write each
  kind to its own column.

  These tests pin the post-code-release write behavior at the
  `Dhc.Workshops` public seam:

    * `complete_member_registration/3` writes the PaymentIntent id to
      `stripe_payment_intent_id`, and its idempotency lookup uses the new
      column.
    * external registration inserts continue to write `cs_*` to
      `stripe_checkout_session_id`.
    * `process_refund/5` resolves the Payment Intent from the checkout
      session for external rows (latent external-refund bug fix) and
      refunds against the resolved `pi_*`.
    * `mark_customer_active/3` wraps its two `update_all`s in a
      `Repo.transaction` so a partial failure self-heals via sync retry.

  Stripe is stubbed via the `:workshop_stripe_client` config injection
  seam (mirroring `DhcWeb.WorkshopsControllerTest`). No Stripe API calls.
  """

  use Dhc.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Dhc.Auth.Principal
  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Repo
  alias Dhc.UserProfiles.UserProfile
  alias Dhc.Workshops
  alias Dhc.Workshops.{PaymentAttempt, Refund, Registration}
  alias Dhc.WorkshopFixtures

  # A test-only Stripe client driven by `Application` env, so individual
  # tests can swap responses without redefining the module. Mirrors the
  # `DhcWeb.WorkshopsControllerTest.StripeClient` shape, handling both the
  # keyword-list `client.request(method: ..., url: ..., body: ...)` calls
  # used by `Dhc.Workshops` and the map `client.request(%{...})` calls used
  # by the generated `Dhc.Stripe.Operations.*` functions.
  defmodule StripeClient do
    def request(%{method: :get, url: url}), do: request(method: :get, url: url)

    def request(%{method: method, url: url, body: body} = request) do
      Application.put_env(
        :dhc,
        :workshop_stripe_test_last_request_opts,
        Map.get(request, :opts, [])
      )

      request(method: method, url: url, body: body)
    end

    def request(method: :post, url: "/v1/payment_intents", body: _body) do
      {:ok,
       %{
         "id" => "pi_test_member",
         "client_secret" => "pi_test_member_secret",
         "amount" => 1000,
         "currency" => "eur",
         "status" => "requires_payment_method",
         "metadata" => %{}
       }}
    end

    def request(method: :get, url: "/v1/payment_intents/" <> payment_intent_id) do
      case Application.get_env(:dhc, :workshop_stripe_test_payment_intent_response) do
        nil ->
          {:ok, pi_retrieve_default(payment_intent_id)}

        other ->
          other
      end
    end

    def request(method: :get, url: "/v1/checkout/sessions/" <> checkout_session_id) do
      case Application.get_env(:dhc, :workshop_stripe_test_checkout_session_response) do
        nil ->
          {:ok, cs_retrieve_default(checkout_session_id)}

        other ->
          other
      end
    end

    def request(method: :post, url: "/v1/refunds", body: body) do
      Application.put_env(:dhc, :workshop_stripe_test_last_refund_request, body)

      case Application.get_env(:dhc, :workshop_stripe_test_refund_response, :ok) do
        :ok -> {:ok, %{"id" => "re_test_member"}}
        other -> other
      end
    end

    def request(_method, _url, _body), do: {:ok, %{}}
    def request(_), do: {:ok, %{}}

    defp pi_retrieve_default(payment_intent_id) do
      %{
        "id" => payment_intent_id,
        "status" => "succeeded",
        "amount" => 1000,
        "currency" => "eur",
        "metadata" => %{
          "type" => "workshop_registration",
          "actor_type" => "member",
          "workshop_id" => Application.fetch_env!(:dhc, :workshop_stripe_test_workshop_id),
          "user_id" => Application.fetch_env!(:dhc, :workshop_stripe_test_member_user_id)
        }
      }
    end

    defp cs_retrieve_default(checkout_session_id) do
      %{
        "id" => checkout_session_id,
        "status" => "complete",
        "payment_status" => "paid",
        "amount_total" => 2000,
        "currency" => "eur",
        "payment_intent" => "pi_from_checkout",
        "metadata" => %{
          "type" => "workshop_registration",
          "actor_type" => "external",
          "workshop_id" => Application.fetch_env!(:dhc, :workshop_stripe_test_workshop_id),
          "payment_attempt_id" =>
            Application.fetch_env!(:dhc, :workshop_stripe_test_payment_attempt_id)
        },
        "customer_details" => %{
          "email" => "guest@example.com",
          "name" => "Grace Hopper",
          "phone" => "+353123456"
        }
      }
    end
  end

  setup do
    original_stripe = Application.get_env(:dhc, :workshop_stripe_client)
    Application.put_env(:dhc, :workshop_stripe_client, StripeClient)

    on_exit(fn ->
      Application.put_env(:dhc, :workshop_stripe_client, original_stripe)
      Application.delete_env(:dhc, :workshop_stripe_test_workshop_id)
      Application.delete_env(:dhc, :workshop_stripe_test_member_user_id)
      Application.delete_env(:dhc, :workshop_stripe_test_payment_intent_response)
      Application.delete_env(:dhc, :workshop_stripe_test_checkout_session_response)
      Application.delete_env(:dhc, :workshop_stripe_test_refund_response)
      Application.delete_env(:dhc, :workshop_stripe_test_last_refund_request)
      Application.delete_env(:dhc, :workshop_stripe_test_last_request_opts)
      Application.delete_env(:dhc, :workshop_stripe_test_payment_attempt_id)
    end)

    :ok
  end

  # ── Member registration writes stripe_payment_intent_id ──────────────

  describe "complete_member_registration/3 writes the split columns" do
    test "writes the PaymentIntent id to stripe_payment_intent_id, not the checkout column" do
      workshop = WorkshopFixtures.workshop_fixture(status: "published", max_capacity: 2)
      %{auth_user_id: user_id} = WorkshopFixtures.member_fixture()

      Application.put_env(:dhc, :workshop_stripe_test_workshop_id, workshop.id)
      Application.put_env(:dhc, :workshop_stripe_test_member_user_id, user_id)

      pi_id = "pi_member_#{System.unique_integer([:positive])}"

      assert {:ok, %Registration{} = registration} =
               Workshops.complete_member_registration(workshop.id, user_id, pi_id)

      assert registration.stripe_payment_intent_id == pi_id
      assert registration.stripe_checkout_session_id == nil
    end

    test "idempotency lookup uses stripe_payment_intent_id: replaying the same PI returns the existing row" do
      workshop = WorkshopFixtures.workshop_fixture(status: "published", max_capacity: 2)
      %{auth_user_id: user_id} = WorkshopFixtures.member_fixture()

      Application.put_env(:dhc, :workshop_stripe_test_workshop_id, workshop.id)
      Application.put_env(:dhc, :workshop_stripe_test_member_user_id, user_id)

      pi_id = "pi_idem_#{System.unique_integer([:positive])}"

      assert {:ok, first} = Workshops.complete_member_registration(workshop.id, user_id, pi_id)
      assert {:ok, second} = Workshops.complete_member_registration(workshop.id, user_id, pi_id)

      assert second.id == first.id
    end
  end

  describe "archived Workshops reject registration" do
    test "member initiation is rejected and a completed payment is durably compensated" do
      workshop = archived_workshop_fixture()
      %{auth_user_id: user_id} = WorkshopFixtures.member_fixture()

      Application.put_env(:dhc, :workshop_stripe_test_workshop_id, workshop.id)
      Application.put_env(:dhc, :workshop_stripe_test_member_user_id, user_id)

      assert {:error, :not_found} =
               Workshops.create_member_payment_intent(workshop.id, user_id, %{amount: 1000})

      payment_intent_id = "pi_archived_#{System.unique_integer([:positive])}"

      assert {:error, :compensation_pending} =
               Workshops.complete_member_registration(workshop.id, user_id, payment_intent_id)

      attempt = Repo.get_by!(PaymentAttempt, stripe_payment_intent_id: payment_intent_id)

      assert %Refund{status: "pending", payment_attempt_id: attempt_id} =
               Repo.get_by!(Refund, payment_attempt_id: attempt.id)

      assert attempt_id == attempt.id
      assert Application.get_env(:dhc, :workshop_stripe_test_last_refund_request) == nil
    end

    test "member completion does not contact Stripe while recording compensation" do
      workshop = archived_workshop_fixture()
      %{auth_user_id: user_id} = WorkshopFixtures.member_fixture()

      Application.put_env(:dhc, :workshop_stripe_test_workshop_id, workshop.id)
      Application.put_env(:dhc, :workshop_stripe_test_member_user_id, user_id)

      Application.put_env(
        :dhc,
        :workshop_stripe_test_refund_response,
        {:error, :provider_unavailable}
      )

      assert {:error, :compensation_pending} =
               Workshops.complete_member_registration(
                 workshop.id,
                 user_id,
                 "pi_archived_refund_failure"
               )

      assert Application.get_env(:dhc, :workshop_stripe_test_last_refund_request) == nil
    end

    test "external gates reject initiation and durably compensate an in-flight paid checkout" do
      workshop = archived_workshop_fixture()
      Application.put_env(:dhc, :workshop_stripe_test_workshop_id, workshop.id)

      assert %{can_register: false, reason: "NOT_FOUND"} =
               Workshops.external_registration_gate(workshop.id)

      assert {:error, :not_found} =
               Workshops.create_external_checkout_session(
                 workshop.id,
                 Ecto.UUID.generate(),
                 "https://example.com/return?session={CHECKOUT_SESSION_ID}"
               )

      checkout_session_id = "cs_archived_#{System.unique_integer([:positive])}"
      payment_attempt_id = Ecto.UUID.generate()
      Application.put_env(:dhc, :workshop_stripe_test_payment_attempt_id, payment_attempt_id)

      Repo.insert!(%PaymentAttempt{
        id: payment_attempt_id,
        club_activity_id: workshop.id,
        actor_type: "external",
        amount: 2000,
        currency: "eur",
        status: "paid",
        stripe_checkout_session_id: checkout_session_id,
        paid_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      assert {:error, :compensation_pending} =
               Workshops.complete_external_registration(workshop.id, checkout_session_id)

      attempt = Repo.get_by!(PaymentAttempt, stripe_checkout_session_id: checkout_session_id)

      assert %Refund{status: "pending", stripe_payment_intent_id: "pi_from_checkout"} =
               Repo.get_by!(Refund, payment_attempt_id: attempt.id)

      assert Application.get_env(:dhc, :workshop_stripe_test_last_refund_request) == nil
    end
  end

  describe "delete and registration serialization" do
    test "a completion holding the Workshop lock commits before deletion decides to archive" do
      {workshop, member} =
        outside_sandbox(fn ->
          workshop = WorkshopFixtures.workshop_fixture(status: "published", max_capacity: 2)
          member = WorkshopFixtures.member_fixture()
          {workshop, member}
        end)

      user_id = member.auth_user_id

      Application.put_env(:dhc, :workshop_stripe_test_workshop_id, workshop.id)
      Application.put_env(:dhc, :workshop_stripe_test_member_user_id, user_id)

      ready_lock = :erlang.phash2({workshop.id, :ready}, 2_000_000_000)
      release_lock = :erlang.phash2({workshop.id, :release}, 2_000_000_000)
      trigger = "test_registration_delay_#{ready_lock}"

      outside_sandbox(fn ->
        install_registration_delay!(trigger, workshop.id, ready_lock, release_lock)
      end)

      on_exit(fn ->
        outside_sandbox(fn ->
          Repo.query!("DROP TRIGGER IF EXISTS #{trigger} ON club_activity_registrations")
          Repo.query!("DROP FUNCTION IF EXISTS #{trigger}()")
          Repo.delete_all(from r in Registration, where: r.club_activity_id == ^workshop.id)
          Repo.delete_all(from pa in PaymentAttempt, where: pa.club_activity_id == ^workshop.id)
          Repo.delete_all(from w in Dhc.Workshops.Workshop, where: w.id == ^workshop.id)
          Repo.delete_all(from mp in MemberProfile, where: mp.id == ^member.principal_id)
          Repo.delete_all(from up in UserProfile, where: up.id == ^member.profile_id)
          Repo.delete_all(from p in Principal, where: p.id == ^member.principal_id)
        end)
      end)

      supervisor = start_supervised!(Task.Supervisor)
      payment_intent_id = "pi_delete_race_#{System.unique_integer([:positive])}"
      test_pid = self()

      coordinator =
        Task.Supervisor.async_nolink(supervisor, fn ->
          outside_sandbox(fn ->
            Repo.transaction(fn ->
              Repo.query!("SELECT pg_advisory_xact_lock($1)", [release_lock])
              send(test_pid, :release_lock_acquired)

              receive do
                :release_registration -> :ok
              end
            end)
          end)
        end)

      assert_receive :release_lock_acquired

      completion =
        Task.Supervisor.async_nolink(supervisor, fn ->
          outside_sandbox(fn ->
            Workshops.complete_member_registration(workshop.id, user_id, payment_intent_id)
          end)
        end)

      outside_sandbox(fn -> await_advisory_lock!(ready_lock, 1_000) end)

      deletion =
        Task.Supervisor.async_nolink(supervisor, fn ->
          outside_sandbox(fn -> Workshops.delete_workshop(workshop.id) end)
        end)

      outside_sandbox(fn -> await_workshop_lock_wait!(1_000) end)
      send(coordinator.pid, :release_registration)

      assert {:ok, %Registration{stripe_payment_intent_id: ^payment_intent_id}} =
               Task.await(completion, :infinity)

      assert {:ok, :archived, _summary} = Task.await(deletion, :infinity)
      assert {:ok, :ok} = Task.await(coordinator, :infinity)
    end
  end

  # ── Refunds resolve the split identifier ─────────────────────────────

  describe "process_refund/5 records durable repayment obligations" do
    # Both member and external registrations must refund against a `pi_*`
    # Payment Intent. Member registrations carry it directly in
    # `stripe_payment_intent_id`. External registrations carry a `cs_*` in
    # `stripe_checkout_session_id`; the refund path resolves the underlying
    # Payment Intent from the checkout session via
    # `stripe_retrieve_checkout_session/1` before calling `/v1/refunds`.

    test "member registration refunds against stripe_payment_intent_id" do
      workshop =
        WorkshopFixtures.workshop_fixture(
          status: "published",
          start_date: DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:second)
        )

      %{auth_user_id: user_id, principal_id: principal_id} =
        WorkshopFixtures.member_fixture()

      Application.put_env(:dhc, :workshop_stripe_test_workshop_id, workshop.id)
      Application.put_env(:dhc, :workshop_stripe_test_member_user_id, user_id)

      pi_id = "pi_refund_member_#{System.unique_integer([:positive])}"

      {:ok, registration} = Workshops.complete_member_registration(workshop.id, user_id, pi_id)

      assert {:ok, refund} =
               Workshops.process_refund(
                 workshop.id,
                 registration.id,
                 "Unable to attend",
                 principal_id
               )

      assert refund.status == "pending"
      assert refund.stripe_refund_id == nil
      assert refund.stripe_payment_intent_id == pi_id
      assert Application.get_env(:dhc, :workshop_stripe_test_last_refund_request) == nil
    end

    test "external registration resolves the Payment Intent from the checkout session" do
      workshop =
        WorkshopFixtures.workshop_fixture(
          status: "published",
          is_public: true,
          price_non_member: 2000.0,
          start_date: DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:second)
        )

      Application.put_env(:dhc, :workshop_stripe_test_workshop_id, workshop.id)

      cs_id = "cs_refund_external_#{System.unique_integer([:positive])}"
      payment_attempt_id = Ecto.UUID.generate()
      Application.put_env(:dhc, :workshop_stripe_test_payment_attempt_id, payment_attempt_id)

      Repo.insert!(%PaymentAttempt{
        id: payment_attempt_id,
        club_activity_id: workshop.id,
        actor_type: "external",
        amount: 2000,
        currency: "eur",
        status: "pending",
        stripe_checkout_session_id: cs_id
      })

      assert {:ok, %Registration{} = registration} =
               Workshops.complete_external_registration(workshop.id, cs_id)

      assert registration.stripe_checkout_session_id == cs_id

      # The refund requested_by must be a real Principal (FK constraint).
      %{principal_id: coordinator_id} = WorkshopFixtures.member_fixture()

      assert {:ok, refund} =
               Workshops.process_refund(
                 workshop.id,
                 registration.id,
                 "External refund",
                 coordinator_id
               )

      assert refund.status == "pending"
      assert refund.stripe_refund_id == nil
      assert refund.stripe_payment_intent_id == nil
      assert Application.get_env(:dhc, :workshop_stripe_test_last_refund_request) == nil
    end

    test "a paid registration with no Stripe id skips the Stripe call and marks refunded" do
      # A registration paid offline (no Stripe Payment Intent or Checkout
      # Session recorded) has nothing to refund against Stripe. The refund
      # is marked refunded without contacting the provider.
      workshop =
        WorkshopFixtures.workshop_fixture(
          status: "published",
          start_date: DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:second)
        )

      %{auth_user_id: user_id, principal_id: principal_id} =
        WorkshopFixtures.member_fixture()

      registration =
        WorkshopFixtures.registration_fixture(
          workshop_id: workshop.id,
          member_user_id: user_id,
          status: "confirmed",
          amount_paid: 1000
        )

      # The cancellation flow skips the paid-deadline eligibility gate.
      assert {:ok, refund} =
               Workshops.process_refund(
                 workshop.id,
                 registration.id,
                 "Offline",
                 principal_id,
                 skip_eligibility: true
               )

      assert refund.status == "pending"

      # No Stripe refund request issued for a no-id registration.
      assert Application.get_env(:dhc, :workshop_stripe_test_last_refund_request) == nil
    end
  end

  defp archived_workshop_fixture do
    workshop =
      WorkshopFixtures.workshop_fixture(
        status: "published",
        is_public: true,
        price_non_member: 2000.0
      )

    workshop
    |> Ecto.Changeset.change(archived_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update!()
  end

  defp outside_sandbox(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp install_registration_delay!(trigger, workshop_id, ready_lock, release_lock) do
    Repo.query!("""
    CREATE FUNCTION #{trigger}() RETURNS trigger AS $$
    BEGIN
      IF NEW.club_activity_id = '#{workshop_id}'::uuid THEN
        PERFORM pg_advisory_xact_lock(#{ready_lock});
        PERFORM pg_advisory_xact_lock(#{release_lock});
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER #{trigger}
    BEFORE INSERT ON club_activity_registrations
    FOR EACH ROW EXECUTE FUNCTION #{trigger}()
    """)
  end

  defp await_advisory_lock!(_lock_key, 0), do: flunk("registration did not reach the insert")

  defp await_advisory_lock!(lock_key, attempts) do
    case Repo.query!("SELECT pg_try_advisory_lock($1)", [lock_key]).rows do
      [[false]] ->
        :ok

      [[true]] ->
        Repo.query!("SELECT pg_advisory_unlock($1)", [lock_key])
        await_advisory_lock!(lock_key, attempts - 1)
    end
  end

  defp await_workshop_lock_wait!(0), do: flunk("deletion did not wait for the Workshop lock")

  defp await_workshop_lock_wait!(attempts) do
    waiting? =
      Repo.query!(
        """
        SELECT EXISTS (
          SELECT 1
            FROM pg_stat_activity
           WHERE pid <> pg_backend_pid()
             AND wait_event_type = 'Lock'
             AND query LIKE $1
             AND query LIKE $2
        )
        """,
        ["%FROM \"club_activities\"%", "%FOR UPDATE%"]
      ).rows == [[true]]

    if waiting?, do: :ok, else: await_workshop_lock_wait!(attempts - 1)
  end
end
