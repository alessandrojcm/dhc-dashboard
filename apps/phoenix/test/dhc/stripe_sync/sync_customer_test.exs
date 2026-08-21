defmodule Dhc.StripeSync.SyncCustomerTest do
  @moduledoc """
  ALE-250: the Stripe-sync price-coverage check must treat a subscription
  with status `trialing` as satisfying its expected membership price,
  alongside the existing `active` requirement.

  Without this, a reactivated member paying monthly while their annual
  subscription awaits a future start date (trial end) is flipped back to
  inactive on the next sync pass.

  These tests exercise `sync_customer/3` through the real repository so the
  resulting membership rows are asserted directly.
  """

  use Dhc.DataCase, async: false

  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Repo
  alias Dhc.StripeSync
  alias Dhc.UserProfiles.UserProfile

  import Ecto.Query

  @price_monthly "price_monthly_test"
  @price_annual "price_annual_test"

  describe "sync_customer/3 price coverage" do
    test "keeps the member active when monthly is active and annual is trialing" do
      fixture = Dhc.MemberFixtures.member_fixture(is_active: false)

      subscriptions = [
        subscription(@price_monthly, "active",
          latest_invoice: %{"status_transitions" => %{"paid_at" => 1_710_000_000}}
        ),
        subscription(@price_annual, "trialing", start_date: 1_720_000_000)
      ]

      assert {:ok, :active} =
               StripeSync.sync_customer(fixture.customer_id, subscriptions, [
                 @price_monthly,
                 @price_annual
               ])

      assert %{is_active: true} = user_profile(fixture)

      member = member_profile(fixture)
      assert %DateTime{} = member.last_payment_date
      assert is_nil(member.subscription_paused_until)
    end

    test "keeps the member active when every covering subscription is trialing" do
      fixture = Dhc.MemberFixtures.member_fixture(is_active: false)

      subscriptions = [
        subscription(@price_monthly, "trialing", start_date: 1_720_000_000),
        subscription(@price_annual, "trialing", start_date: 1_730_000_000)
      ]

      assert {:ok, :active} =
               StripeSync.sync_customer(fixture.customer_id, subscriptions, [
                 @price_monthly,
                 @price_annual
               ])

      assert %{is_active: true} = user_profile(fixture)
      assert %DateTime{} = member_profile(fixture).last_payment_date
    end

    test "marks the member inactive when a trialing sub covers only one of the prices" do
      fixture = Dhc.MemberFixtures.member_fixture(is_active: true)

      subscriptions = [
        subscription(@price_monthly, "trialing", start_date: 1_720_000_000),
        subscription(@price_annual, "canceled")
      ]

      assert {:ok, :inactive} =
               StripeSync.sync_customer(fixture.customer_id, subscriptions, [
                 @price_monthly,
                 @price_annual
               ])

      assert %{is_active: false} = user_profile(fixture)
    end

    test "marks the member inactive when a price has no active or trialing subscription" do
      fixture = Dhc.MemberFixtures.member_fixture(is_active: true)

      subscriptions = [
        subscription(@price_monthly, "active",
          latest_invoice: %{"status_transitions" => %{"paid_at" => 1_710_000_000}}
        ),
        subscription(@price_annual, "canceled")
      ]

      assert {:ok, :inactive} =
               StripeSync.sync_customer(fixture.customer_id, subscriptions, [
                 @price_monthly,
                 @price_annual
               ])

      assert %{is_active: false} = user_profile(fixture)
    end

    test "marks customers without any membership subscription inactive" do
      fixture = Dhc.MemberFixtures.member_fixture(is_active: true)

      assert {:ok, :inactive} =
               StripeSync.sync_customer(fixture.customer_id, nil, [
                 @price_monthly,
                 @price_annual
               ])

      assert %{is_active: false} = user_profile(fixture)
    end
  end

  describe "sync_customer/3 pause detection" do
    test "resolves paused when a covered active subscription has pause_collection" do
      fixture = Dhc.MemberFixtures.member_fixture(is_active: true)

      resumes_at = DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.to_unix()

      subscriptions = [
        subscription(@price_monthly, "active",
          latest_invoice: %{"status_transitions" => %{"paid_at" => 1_710_000_000}},
          pause_collection: %{"behavior" => "void", "resumes_at" => resumes_at}
        ),
        subscription(@price_annual, "active")
      ]

      assert {:ok, :paused} =
               StripeSync.sync_customer(fixture.customer_id, subscriptions, [
                 @price_monthly,
                 @price_annual
               ])

      assert %{is_active: true} = user_profile(fixture)
      assert %DateTime{} = member_profile(fixture).subscription_paused_until
    end

    test "resolves paused when a covered trialing subscription has pause_collection" do
      fixture = Dhc.MemberFixtures.member_fixture(is_active: true)

      resumes_at = DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.to_unix()

      subscriptions = [
        subscription(@price_monthly, "active"),
        subscription(@price_annual, "trialing",
          start_date: 1_720_000_000,
          pause_collection: %{"behavior" => "void", "resumes_at" => resumes_at}
        )
      ]

      assert {:ok, :paused} =
               StripeSync.sync_customer(fixture.customer_id, subscriptions, [
                 @price_monthly,
                 @price_annual
               ])

      assert %{is_active: true} = user_profile(fixture)
      assert %DateTime{} = member_profile(fixture).subscription_paused_until
    end

    test "still marks the member inactive when pause_collection exists but coverage is incomplete" do
      fixture = Dhc.MemberFixtures.member_fixture(is_active: true)

      resumes_at = DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.to_unix()

      subscriptions = [
        subscription(@price_monthly, "active",
          latest_invoice: %{"status_transitions" => %{"paid_at" => 1_710_000_000}},
          pause_collection: %{"behavior" => "void", "resumes_at" => resumes_at}
        )
      ]

      assert {:ok, :inactive} =
               StripeSync.sync_customer(fixture.customer_id, subscriptions, [
                 @price_monthly,
                 @price_annual
               ])

      assert %{is_active: false} = user_profile(fixture)
    end
  end

  defp subscription(price_id, status, opts \\ []) do
    %{
      "id" => "sub_#{System.unique_integer([:positive])}",
      "customer" => "cus_test",
      "object" => "subscription",
      "status" => status,
      "created" => 1_700_000_000,
      "start_date" => Keyword.get(opts, :start_date),
      "pause_collection" => Keyword.get(opts, :pause_collection),
      "items" => %{
        "object" => "list",
        "data" => [%{"object" => "subscription_item", "price" => %{"id" => price_id}}]
      },
      "latest_invoice" => Keyword.get(opts, :latest_invoice)
    }
  end

  defp user_profile(fixture) do
    Repo.one!(
      from(up in UserProfile,
        where: up.id == ^fixture.profile_id,
        select: %{is_active: up.is_active}
      )
    )
  end

  defp member_profile(fixture) do
    Repo.one!(
      from(mp in MemberProfile,
        where: mp.user_profile_id == ^fixture.profile_id,
        select: %{
          last_payment_date: mp.last_payment_date,
          subscription_paused_until: mp.subscription_paused_until
        }
      )
    )
  end
end
