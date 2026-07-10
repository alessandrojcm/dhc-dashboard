defmodule Dhc.StripeWebhooksChargeRegistrationTest do
  @moduledoc """
  Side-effect tests for the charge → workshop-registration pipeline.

  The webhook controller tests (`DhcWeb.StripeWebhooksControllerTest`) verify
  signature validation and job enqueueing. The context tests
  (`Dhc.StripeWebhooksTest`) verify malformed-event handling and the no-op
  branches for charges without workshop metadata. **Neither exercises the
  actual DB side effect** — `confirm_workshop_registration` /
  `cancel_expired_workshop_registration` — which is the entire reason the
  webhook exists.

  These tests cover the missing behavior at the `StripeWebhooks.process_event/1`
  seam:

    * `charge.succeeded` with workshop metadata confirms a pending registration
      and stamps `confirmed_at`.
    * The same event replayed is idempotent — the DB `WHERE status = 'pending'`
      guard is the contract, not a processed-events table or Oban `unique`.
    * `charge.expired` with workshop metadata cancels a pending registration
      and stamps `cancelled_at`.

  Idempotency seam: **DB-guard**. Stripe retries delivered events; the
  `WHERE stripe_checkout_session_id = ? AND status = 'pending'` clause makes
  the second delivery a no-op (`{0, _} → :ok`). No processed-events table,
  no Oban unique constraint — the guard is the contract. These tests lock that
  in so a future "optimization" that drops the `status` predicate or swaps
  to fire-and-forget cannot silently double-confirm.
  """

  use Dhc.DataCase, async: false

  alias Dhc.Repo
  alias Dhc.StripeWebhooks
  alias Dhc.Workshops.Registration
  alias Dhc.WorkshopFixtures

  describe "charge.succeeded with workshop metadata" do
    test "confirms a pending registration and stamps confirmed_at" do
      workshop = WorkshopFixtures.workshop_fixture()
      external = WorkshopFixtures.external_user_fixture()
      charge_id = "ch_test_confirm_#{System.unique_integer([:positive])}"

      registration =
        insert_pending_registration(workshop.id, external.id, charge_id)

      event = charge_succeeded_event(charge_id, workshop.id, amount: 2000)

      assert :ok = StripeWebhooks.process_event(event)

      reloaded = Repo.get!(Registration, registration.id)
      assert reloaded.status == "confirmed"
      assert reloaded.confirmed_at != nil
    end

    test "is idempotent: replaying the same event does not re-stamp confirmed_at" do
      workshop = WorkshopFixtures.workshop_fixture()
      external = WorkshopFixtures.external_user_fixture()
      charge_id = "ch_test_idempotent_#{System.unique_integer([:positive])}"

      registration =
        insert_pending_registration(workshop.id, external.id, charge_id)

      event = charge_succeeded_event(charge_id, workshop.id, amount: 2500)

      assert :ok = StripeWebhooks.process_event(event)

      confirmed = Repo.get!(Registration, registration.id)
      assert confirmed.status == "confirmed"
      stamped_at = confirmed.confirmed_at

      # Replay — Stripe redelivers events on retry. The DB guard
      # (`WHERE status = 'pending'`) makes this a no-op, not an error.
      assert :ok = StripeWebhooks.process_event(event)

      reloaded = Repo.get!(Registration, registration.id)
      assert reloaded.status == "confirmed"
      # confirmed_at was NOT overwritten by the replay.
      assert reloaded.confirmed_at == stamped_at
    end

    test "returning :ok for a charge with no matching pending registration" do
      # A charge that has workshop metadata but no matching registration row
      # (e.g. the registration was deleted or already confirmed out-of-band).
      workshop = WorkshopFixtures.workshop_fixture()
      charge_id = "ch_orphan_#{System.unique_integer([:positive])}"

      event = charge_succeeded_event(charge_id, workshop.id, amount: 1000)

      # No registration seeded — the {0, _} branch must return :ok, not error.
      assert :ok = StripeWebhooks.process_event(event)
    end
  end

  describe "charge.expired with workshop metadata" do
    test "cancels a pending registration and stamps cancelled_at" do
      workshop = WorkshopFixtures.workshop_fixture()
      external = WorkshopFixtures.external_user_fixture()
      charge_id = "ch_expired_#{System.unique_integer([:positive])}"

      registration =
        insert_pending_registration(workshop.id, external.id, charge_id)

      event = charge_expired_event(charge_id, workshop.id)

      assert :ok = StripeWebhooks.process_event(event)

      reloaded = Repo.get!(Registration, registration.id)
      assert reloaded.status == "cancelled"
      assert reloaded.cancelled_at != nil
    end

    test "is idempotent: replaying does not re-stamp cancelled_at" do
      workshop = WorkshopFixtures.workshop_fixture()
      external = WorkshopFixtures.external_user_fixture()
      charge_id = "ch_expired_idempotent_#{System.unique_integer([:positive])}"

      registration =
        insert_pending_registration(workshop.id, external.id, charge_id)

      event = charge_expired_event(charge_id, workshop.id)

      assert :ok = StripeWebhooks.process_event(event)

      cancelled = Repo.get!(Registration, registration.id)
      assert cancelled.status == "cancelled"
      stamped_at = cancelled.cancelled_at

      assert :ok = StripeWebhooks.process_event(event)

      reloaded = Repo.get!(Registration, registration.id)
      assert reloaded.status == "cancelled"
      assert reloaded.cancelled_at == stamped_at
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  defp insert_pending_registration(workshop_id, external_user_id, charge_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, registration} =
      %Registration{
        club_activity_id: workshop_id,
        external_user_id: external_user_id,
        stripe_checkout_session_id: charge_id,
        amount_paid: 2000,
        currency: "eur",
        status: "pending",
        registered_at: now
      }
      |> Repo.insert()

    registration
  end

  defp charge_succeeded_event(charge_id, workshop_id, opts) do
    %{
      "type" => "charge.succeeded",
      "data" => %{
        "object" => %{
          "id" => charge_id,
          "amount" => Keyword.get(opts, :amount, 1000),
          "metadata" => %{
            "workshop_id" => workshop_id,
            "registration_data" => "test"
          }
        }
      }
    }
  end

  defp charge_expired_event(charge_id, workshop_id) do
    %{
      "type" => "charge.expired",
      "data" => %{
        "object" => %{
          "id" => charge_id,
          "metadata" => %{
            "workshop_id" => workshop_id
          }
        }
      }
    }
  end
end
