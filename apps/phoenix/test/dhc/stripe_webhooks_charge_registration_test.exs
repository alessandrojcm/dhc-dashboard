defmodule Dhc.StripeWebhooksChargeRegistrationTest do
  @moduledoc """
  Charge-event side-effect tests after the ALE-193 code release.

  The dead `ch_*` webhook handlers `confirm_workshop_registration` /
  `cancel_expired_workshop_registration` matched charge ids against
  `stripe_checkout_session_id`, a column that only ever holds `pi_*` /
  `cs_*` ids — a `charge.*` event's `id` is a `ch_*` that never matches, so
  both handlers always no-op'd. The ALE-193 code release deletes them: no
  path reads the old `ch_*` charge id against the registration table.

  After deletion, `charge.succeeded` and `charge.expired` with workshop
  metadata fall through to the customer-sync / no-op branches exactly like
  the non-workshop-metadata branches. They must NOT mutate registration
  status — a pending registration stays pending (the registration
  confirmation path is `complete_member_registration` / the external
  checkout completion, driven by `payment_intent.*` / checkout events, not
  `charge.*` events).
  """

  use Dhc.DataCase, async: false

  alias Dhc.Repo
  alias Dhc.StripeWebhooks
  alias Dhc.Workshops.Registration
  alias Dhc.WorkshopFixtures

  describe "charge.succeeded with workshop metadata" do
    test "does not confirm a pending registration (the ch_ handler is deleted)" do
      workshop = WorkshopFixtures.workshop_fixture()
      external = WorkshopFixtures.external_user_fixture()
      # A real charge id is ch_*, which the deleted handler matched against a
      # column that only holds pi_/cs_ — it never matched. Pin the post-
      # deletion behavior: the registration is untouched.
      charge_id = "ch_test_confirm_#{System.unique_integer([:positive])}"

      registration =
        insert_pending_registration(workshop.id, external.id, "pi_real_#{charge_id}")

      event = charge_succeeded_event(charge_id, workshop.id, amount: 2000)

      assert :ok = StripeWebhooks.process_event(event)

      reloaded = Repo.get!(Registration, registration.id)
      # The dead handler is gone — the charge event no longer confirms.
      assert reloaded.status == "pending"
      assert is_nil(reloaded.confirmed_at)
    end

    test "does not confirm even when a registration reuses the charge id (the handler is deleted)" do
      # The pre-deletion tests seeded stripe_checkout_session_id with the
      # charge id to fake a match. After deletion the handler is gone, so
      # even that contrived row is untouched — nothing reads
      # stripe_checkout_session_id for charge events anymore.
      workshop = WorkshopFixtures.workshop_fixture()
      external = WorkshopFixtures.external_user_fixture()
      charge_id = "ch_fake_match_#{System.unique_integer([:positive])}"

      registration =
        insert_pending_registration_cs(workshop.id, external.id, charge_id)

      event = charge_succeeded_event(charge_id, workshop.id, amount: 2000)

      assert :ok = StripeWebhooks.process_event(event)

      reloaded = Repo.get!(Registration, registration.id)
      assert reloaded.status == "pending"
      assert is_nil(reloaded.confirmed_at)
    end

    test "returns :ok for a charge with no matching registration" do
      workshop = WorkshopFixtures.workshop_fixture()
      charge_id = "ch_orphan_#{System.unique_integer([:positive])}"

      event = charge_succeeded_event(charge_id, workshop.id, amount: 1000)

      # No registration seeded — the fall-through returns :ok, not an error.
      assert :ok = StripeWebhooks.process_event(event)
    end
  end

  describe "charge.expired with workshop metadata" do
    test "does not cancel a pending registration (the ch_ handler is deleted)" do
      workshop = WorkshopFixtures.workshop_fixture()
      external = WorkshopFixtures.external_user_fixture()
      charge_id = "ch_expired_#{System.unique_integer([:positive])}"

      registration =
        insert_pending_registration(workshop.id, external.id, "pi_real_#{charge_id}")

      event = charge_expired_event(charge_id, workshop.id)

      assert :ok = StripeWebhooks.process_event(event)

      reloaded = Repo.get!(Registration, registration.id)
      # The dead handler is gone — the charge event no longer cancels.
      assert reloaded.status == "pending"
      assert is_nil(reloaded.cancelled_at)
    end

    test "does not cancel even when a registration reuses the charge id (the handler is deleted)" do
      workshop = WorkshopFixtures.workshop_fixture()
      external = WorkshopFixtures.external_user_fixture()
      charge_id = "ch_fake_expired_#{System.unique_integer([:positive])}"

      registration =
        insert_pending_registration_cs(workshop.id, external.id, charge_id)

      event = charge_expired_event(charge_id, workshop.id)

      assert :ok = StripeWebhooks.process_event(event)

      reloaded = Repo.get!(Registration, registration.id)
      assert reloaded.status == "pending"
      assert is_nil(reloaded.cancelled_at)
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  defp insert_pending_registration(workshop_id, external_user_id, pi_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, registration} =
      %Registration{
        club_activity_id: workshop_id,
        external_user_id: external_user_id,
        stripe_payment_intent_id: pi_id,
        amount_paid: 2000,
        currency: "eur",
        status: "pending",
        registered_at: now
      }
      |> Repo.insert()

    registration
  end

  # Seeds the registration with the charge id in stripe_checkout_session_id,
  # mirroring how the pre-deletion tests faked a match. After the handler
  # is deleted this row is untouched.
  defp insert_pending_registration_cs(workshop_id, external_user_id, cs_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, registration} =
      %Registration{
        club_activity_id: workshop_id,
        external_user_id: external_user_id,
        stripe_checkout_session_id: cs_id,
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
