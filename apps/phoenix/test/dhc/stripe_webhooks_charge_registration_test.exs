defmodule Dhc.StripeWebhooksChargeRegistrationTest do
  @moduledoc """
  `charge.*` events are not in the `Dhc.StripeWebhooks` routing table
  (ALE-341): they are acknowledged as unknown and must not mutate any
  Registration — a pending registration stays pending. Registration
  confirmation is driven by Workshop payment completion, never `charge.*`.
  """

  use Dhc.DataCase, async: false

  alias Dhc.Repo
  alias Dhc.StripeWebhooks
  alias Dhc.Workshops.Registration
  alias Dhc.WorkshopFixtures

  for type <- ["charge.succeeded", "charge.expired", "charge.refunded"] do
    test "#{type} with workshop metadata is acknowledged and changes no Registration" do
      workshop = WorkshopFixtures.workshop_fixture()
      external = WorkshopFixtures.external_user_fixture()
      charge_id = "ch_test_#{System.unique_integer([:positive])}"

      registration = insert_pending_registration(workshop.id, external.id, "pi_real_#{charge_id}")

      assert :ok =
               StripeWebhooks.process_event(charge_event(unquote(type), charge_id, workshop.id))

      reloaded = Repo.get!(Registration, registration.id)
      assert reloaded.status == "pending"
      assert is_nil(reloaded.confirmed_at)
      assert is_nil(reloaded.cancelled_at)
    end
  end

  defp insert_pending_registration(workshop_id, external_user_id, pi_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %Registration{
      club_activity_id: workshop_id,
      external_user_id: external_user_id,
      display_name: "External Guest",
      stripe_payment_intent_id: pi_id,
      amount_paid: 2000,
      currency: "eur",
      status: "pending",
      registered_at: now
    }
    |> Repo.insert!()
  end

  defp charge_event(type, charge_id, workshop_id) do
    %{
      "type" => type,
      "data" => %{
        "object" => %{
          "id" => charge_id,
          "amount" => 2000,
          "customer" => "cus_charge_#{charge_id}",
          "payment_intent" => "pi_real_#{charge_id}",
          "metadata" => %{"workshop_id" => workshop_id, "registration_data" => "test"}
        }
      }
    }
  end
end
