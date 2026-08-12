defmodule Dhc.StripeSync.WorkerIntegrationTest do
  @moduledoc """
  End-to-end test for the Stripe sync worker against Stripe test mode.

  This test hits the real Stripe test API using `STRIPE_SECRET_KEY`, seeds local
  member rows for configured Stripe customer IDs, runs the worker, and verifies
  the resulting database state.

  Tagged `:integration` so it is excluded from the normal test run.
  """

  use Dhc.DataCase, async: false

  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Repo
  alias Dhc.Stripe.Client, as: StripeClient
  alias Dhc.Stripe.LookupKeys
  alias Dhc.StripeSync.Worker

  import Ecto.Query

  @moduletag :integration

  @stripe_api_url "https://api.stripe.com"
  @price_setting_key "stripe_membership_price_ids"
  describe "perform/1 against Stripe test mode" do
    setup do
      original_url = Application.get_env(:dhc, :stripe_api_url)
      original_key = Application.get_env(:dhc, :stripe_secret_key)

      stripe_secret_key =
        System.get_env("STRIPE_SECRET_KEY") ||
          raise """
          STRIPE_SECRET_KEY is required for #{__MODULE__}.

          Use a Stripe *test mode* secret key and run with:

              mix test test/dhc/stripe_sync/workers/worker_integration_test.exs --include integration
          """

      Application.put_env(
        :dhc,
        :stripe_api_url,
        System.get_env("STRIPE_API_URL", @stripe_api_url)
      )

      Application.put_env(:dhc, :stripe_secret_key, stripe_secret_key)

      on_exit(fn ->
        Application.put_env(:dhc, :stripe_api_url, original_url)
        Application.put_env(:dhc, :stripe_secret_key, original_key)
      end)

      :ok
    end

    test "creates Stripe test fixtures and syncs them into local membership state" do
      price_ids = membership_price_ids!()
      maybe_seed_price_cache(price_ids)

      stripe_fixtures = create_stripe_fixtures!(price_ids)

      try do
        fixtures =
          stripe_fixtures
          |> Enum.map(fn {scenario, stripe_fixture} ->
            {scenario, Dhc.MemberFixtures.member_fixture(customer_id: stripe_fixture.customer_id)}
          end)

        customer_ids = Enum.map(fixtures, fn {_scenario, fixture} -> fixture.customer_id end)

        assert :ok =
                 Worker.perform(%Oban.Job{
                   args: %{"customer_ids" => customer_ids}
                 })

        Enum.each(fixtures, fn
          {:active, fixture} -> assert_active_member(fixture)
          {:paused, fixture} -> assert_paused_member(fixture)
          {:inactive, fixture} -> assert_inactive_member(fixture)
          {:missing, fixture} -> assert_inactive_member(fixture)
        end)
      after
        cleanup_stripe_fixtures(stripe_fixtures)
      end
    end
  end

  defp create_stripe_fixtures!(price_ids) do
    run_id = "dhc-stripe-sync-#{System.unique_integer([:positive])}"

    active_customer = create_customer!(run_id, "active")
    active_subscriptions = create_subscriptions!(active_customer["id"], price_ids)

    paused_customer = create_customer!(run_id, "paused")
    paused_subscriptions = create_subscriptions!(paused_customer["id"], price_ids)
    paused_subscriptions |> List.first() |> Map.fetch!("id") |> pause_subscription!()

    inactive_customer = create_customer!(run_id, "inactive")
    inactive_subscriptions = create_subscriptions!(inactive_customer["id"], price_ids)
    inactive_subscriptions |> List.first() |> Map.fetch!("id") |> cancel_subscription!()

    missing_customer = create_customer!(run_id, "missing")

    %{
      active: %{
        customer_id: active_customer["id"],
        subscription_ids: Enum.map(active_subscriptions, & &1["id"])
      },
      paused: %{
        customer_id: paused_customer["id"],
        subscription_ids: Enum.map(paused_subscriptions, & &1["id"])
      },
      inactive: %{
        customer_id: inactive_customer["id"],
        subscription_ids: Enum.map(inactive_subscriptions, & &1["id"])
      },
      missing: %{customer_id: missing_customer["id"], subscription_ids: []}
    }
  end

  defp create_subscriptions!(customer_id, price_ids) do
    Enum.map(price_ids, &create_subscription!(customer_id, &1))
  end

  defp create_customer!(run_id, scenario) do
    stripe_request!(:post, "/v1/customers", %{
      "name" => "DHC Stripe Sync #{scenario}",
      "email" => "#{run_id}-#{scenario}@example.com",
      "metadata[test_run]" => run_id,
      "metadata[scenario]" => scenario
    })
  end

  defp create_subscription!(customer_id, price_id) do
    stripe_request!(:post, "/v1/subscriptions", %{
      "customer" => customer_id,
      "items[0][price]" => price_id,
      "collection_method" => "send_invoice",
      "days_until_due" => 30
    })
  end

  defp pause_subscription!(subscription_id) do
    resumes_at = DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.to_unix()

    stripe_request!(:post, "/v1/subscriptions/#{subscription_id}", %{
      "pause_collection[behavior]" => "void",
      "pause_collection[resumes_at]" => resumes_at
    })
  end

  defp cancel_subscription!(subscription_id) do
    stripe_request!(:delete, "/v1/subscriptions/#{subscription_id}")
  end

  defp cleanup_stripe_fixtures(stripe_fixtures) do
    stripe_fixtures
    |> Map.values()
    |> Enum.each(fn fixture ->
      Enum.each(fixture.subscription_ids, &maybe_cancel_subscription/1)

      maybe_delete_customer(fixture.customer_id)
    end)
  end

  defp maybe_cancel_subscription(nil), do: :ok

  defp maybe_cancel_subscription(subscription_id) do
    try do
      cancel_subscription!(subscription_id)
      :ok
    rescue
      _ -> :ok
    end
  end

  defp maybe_delete_customer(customer_id) do
    try do
      stripe_request!(:delete, "/v1/customers/#{customer_id}")
      :ok
    rescue
      _ -> :ok
    end
  end

  defp stripe_request!(method, path, body \\ nil) do
    case StripeClient.request(method: method, url: path, body: body) do
      {:ok, response} -> response
      {:error, reason} -> raise "Stripe test API request failed: #{inspect(reason)}"
    end
  end

  defp membership_price_ids! do
    price_ids =
      case System.get_env("STRIPE_SYNC_TEST_PRICE_IDS") do
        nil -> fetch_membership_price_ids!()
        value -> String.split(value, ",", trim: true)
      end

    expected_count = length(LookupKeys.all())

    if length(price_ids) == expected_count do
      price_ids
    else
      raise "Expected #{expected_count} Stripe membership price IDs, got #{length(price_ids)}"
    end
  end

  defp fetch_membership_price_ids! do
    Enum.map(LookupKeys.all(), fn lookup_key ->
      case stripe_get!("/v1/prices", %{
             "lookup_keys[]" => lookup_key,
             active: "true",
             limit: 1
           }) do
        %{"data" => [%{"id" => price_id} | _]} ->
          price_id

        %{"data" => []} ->
          raise """
          Stripe test mode has no active price with lookup_key=#{lookup_key}.

          Set STRIPE_SYNC_TEST_PRICE_IDS=price_monthly,... or create the test price in Stripe.
          """
      end
    end)
  end

  defp stripe_get!(path, params) do
    case Req.get(
           Application.fetch_env!(:dhc, :stripe_api_url) <> path,
           headers: stripe_headers(),
           params: params,
           decode_body: true,
           retry: false,
           connect_options: [timeout: 30_000]
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        body

      {:ok, %Req.Response{status: status, body: body}} ->
        raise "Stripe test API returned #{status}: #{inspect(body)}"

      {:error, exception} ->
        raise "Stripe test API request failed: #{inspect(exception)}"
    end
  end

  defp stripe_headers do
    [
      {"authorization", "Bearer #{Application.fetch_env!(:dhc, :stripe_secret_key)}"},
      {"stripe-version", Application.fetch_env!(:dhc, :stripe_api_version)},
      {"content-type", "application/x-www-form-urlencoded"}
    ]
  end

  defp maybe_seed_price_cache([]), do: :ok

  defp maybe_seed_price_cache(price_ids) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all(
      "settings",
      [
        [
          key: @price_setting_key,
          value: Enum.join(price_ids, ","),
          type: "text",
          created_at: now,
          updated_at: now
        ]
      ],
      on_conflict: {:replace, [:value, :type, :updated_at]},
      conflict_target: [:key]
    )

    :ok
  end

  defp assert_active_member(fixture) do
    assert %{is_active: true} = user_profile(fixture)

    member = member_profile(fixture)
    assert %DateTime{} = member.last_payment_date
    assert is_nil(member.subscription_paused_until)
  end

  defp assert_paused_member(fixture) do
    assert %{is_active: true} = user_profile(fixture)

    member = member_profile(fixture)
    assert %DateTime{} = member.subscription_paused_until
  end

  defp assert_inactive_member(fixture) do
    assert %{is_active: false} = user_profile(fixture)
  end

  defp user_profile(fixture) do
    Repo.one!(
      from(up in "user_profiles",
        where: up.id == type(^fixture.profile_id, Ecto.UUID),
        select: %{is_active: up.is_active}
      )
    )
  end

  defp member_profile(fixture) do
    Repo.one!(
      from(mp in MemberProfile,
        where: mp.user_profile_id == type(^fixture.profile_id, Ecto.UUID),
        select: %{
          last_payment_date: mp.last_payment_date,
          subscription_paused_until: mp.subscription_paused_until,
          membership_end_date: mp.membership_end_date
        }
      )
    )
  end
end
