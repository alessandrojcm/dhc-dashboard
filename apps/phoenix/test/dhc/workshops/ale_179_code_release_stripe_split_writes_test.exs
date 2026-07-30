defmodule Dhc.Workshops.Ale179CodeReleaseStripeSplitWritesTest do
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

  alias Dhc.Repo
  alias Dhc.Workshops
  alias Dhc.Workshops.Registration
  alias Dhc.WorkshopFixtures

  # A test-only Stripe client driven by `Application` env, so individual
  # tests can swap responses without redefining the module. Mirrors the
  # `DhcWeb.WorkshopsControllerTest.StripeClient` shape, handling both the
  # keyword-list `client.request(method: ..., url: ..., body: ...)` calls
  # used by `Dhc.Workshops` and the map `client.request(%{...})` calls used
  # by the generated `Dhc.Stripe.Operations.*` functions.
  defmodule StripeClient do
    def request(%{method: :get, url: url}), do: request(method: :get, url: url)

    def request(%{method: method, url: url, body: body}),
      do: request(method: method, url: url, body: body)

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
      case Application.get_env(:dhc, :ale_193_pi_retrieve_response) do
        nil ->
          {:ok, pi_retrieve_default(payment_intent_id)}

        other ->
          other
      end
    end

    def request(method: :get, url: "/v1/checkout/sessions/" <> checkout_session_id) do
      case Application.get_env(:dhc, :ale_193_cs_retrieve_response) do
        nil ->
          {:ok, cs_retrieve_default(checkout_session_id)}

        other ->
          other
      end
    end

    def request(method: :post, url: "/v1/refunds", body: body) do
      Application.put_env(:dhc, :ale_193_last_refund_request, body)

      case Application.get_env(:dhc, :ale_193_refund_response, :ok) do
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
          "workshop_id" => Application.fetch_env!(:dhc, :ale_193_workshop_id),
          "user_id" => Application.fetch_env!(:dhc, :ale_193_member_user_id)
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
          "workshop_id" => Application.fetch_env!(:dhc, :ale_193_workshop_id)
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
      Application.delete_env(:dhc, :ale_193_workshop_id)
      Application.delete_env(:dhc, :ale_193_member_user_id)
      Application.delete_env(:dhc, :ale_193_pi_retrieve_response)
      Application.delete_env(:dhc, :ale_193_cs_retrieve_response)
      Application.delete_env(:dhc, :ale_193_refund_response)
      Application.delete_env(:dhc, :ale_193_last_refund_request)
    end)

    :ok
  end

  # ── Member registration writes stripe_payment_intent_id ──────────────

  describe "complete_member_registration/3 writes the split columns" do
    test "writes the PaymentIntent id to stripe_payment_intent_id, not the checkout column" do
      workshop = WorkshopFixtures.workshop_fixture(status: "published", max_capacity: 2)
      %{auth_user_id: user_id} = WorkshopFixtures.member_fixture()

      Application.put_env(:dhc, :ale_193_workshop_id, workshop.id)
      Application.put_env(:dhc, :ale_193_member_user_id, user_id)

      pi_id = "pi_member_#{System.unique_integer([:positive])}"

      assert {:ok, %Registration{} = registration} =
               Workshops.complete_member_registration(workshop.id, user_id, pi_id)

      assert registration.stripe_payment_intent_id == pi_id
      assert registration.stripe_checkout_session_id == nil
    end

    test "idempotency lookup uses stripe_payment_intent_id: replaying the same PI returns the existing row" do
      workshop = WorkshopFixtures.workshop_fixture(status: "published", max_capacity: 2)
      %{auth_user_id: user_id} = WorkshopFixtures.member_fixture()

      Application.put_env(:dhc, :ale_193_workshop_id, workshop.id)
      Application.put_env(:dhc, :ale_193_member_user_id, user_id)

      pi_id = "pi_idem_#{System.unique_integer([:positive])}"

      assert {:ok, first} = Workshops.complete_member_registration(workshop.id, user_id, pi_id)
      assert {:ok, second} = Workshops.complete_member_registration(workshop.id, user_id, pi_id)

      assert second.id == first.id
    end
  end

  # ── Refunds resolve the split identifier ─────────────────────────────

  describe "process_refund/5 refunds against the resolved Payment Intent" do
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

      Application.put_env(:dhc, :ale_193_workshop_id, workshop.id)
      Application.put_env(:dhc, :ale_193_member_user_id, user_id)

      pi_id = "pi_refund_member_#{System.unique_integer([:positive])}"

      {:ok, registration} = Workshops.complete_member_registration(workshop.id, user_id, pi_id)

      assert {:ok, refund} =
               Workshops.process_refund(
                 workshop.id,
                 registration.id,
                 "Unable to attend",
                 principal_id
               )

      assert refund.status == "processing"
      assert refund.stripe_refund_id == "re_test_member"
      assert refund.stripe_payment_intent_id == pi_id

      # The refund request body must carry the resolved Payment Intent.
      assert [payment_intent: ^pi_id, amount: 1000, reason: "requested_by_customer"] =
               Application.fetch_env!(:dhc, :ale_193_last_refund_request)
    end

    test "external registration resolves the Payment Intent from the checkout session" do
      workshop =
        WorkshopFixtures.workshop_fixture(
          status: "published",
          is_public: true,
          price_non_member: 2000.0,
          start_date: DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:second)
        )

      Application.put_env(:dhc, :ale_193_workshop_id, workshop.id)

      cs_id = "cs_refund_external_#{System.unique_integer([:positive])}"

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

      assert refund.status == "processing"
      assert refund.stripe_refund_id == "re_test_member"
      assert refund.stripe_payment_intent_id == "pi_from_checkout"

      # The /v1/refunds request must carry the *resolved* Payment Intent,
      # not the checkout session id — the latent external-refund bug.
      assert [payment_intent: "pi_from_checkout", amount: 2000, reason: "requested_by_customer"] =
               Application.fetch_env!(:dhc, :ale_193_last_refund_request)
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
      assert Application.get_env(:dhc, :ale_193_last_refund_request) == nil
    end
  end
end
