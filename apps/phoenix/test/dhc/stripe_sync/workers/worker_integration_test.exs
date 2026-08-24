defmodule Dhc.StripeSync.WorkerIntegrationTest do
  @moduledoc """
  End-to-end test for the Stripe sync worker against Stripe test mode.

  This test hits the real Stripe test API using `STRIPE_SECRET_KEY`, seeds local
  member rows for configured Stripe customer IDs, runs the worker, and verifies
  the resulting database state.

  Tagged `:integration` so it is excluded from the normal test run.

  ## Last payment date contract

  The active-scenario fixture creates its subscription with
  `collection_method=charge_automatically`, a test-mode Visa payment method,
  and `backdate_start_date` 14 days in the past. Stripe therefore issues and
  charges the first invoice during the create call, so the subscription's
  `start_date` is ~14 days before its `latest_invoice.status_transitions.paid_at`.
  The sync must store that `paid_at` as the member's `last_payment_date` —
  never falling back to `start_date`. That fallback is what happens without
  `expand[]=data.latest_invoice` on the subscription list request (Stripe then
  returns `latest_invoice` as a bare ID), and it made every paying member look
  like their last payment was from whenever they originally subscribed.
  """

  use Dhc.DataCase, async: false

  alias Dhc.MemberProfiles.MemberProfile
  alias Dhc.Repo
  alias Dhc.Stripe.Client, as: StripeClient
  alias Dhc.Stripe.LookupKeys
  alias Dhc.StripeSync.Worker

  import Ecto.Query

  @moduletag :integration
  # The worker pages every subscription for every membership price in test
  # mode; a single list page can take tens of seconds against api.stripe.com.
  @moduletag timeout: 600_000

  @stripe_api_url "https://api.stripe.com"
  @price_setting_key "stripe_membership_price_ids"
  # How far back the active scenario's subscription is backdated. Must be far
  # enough that start_date cannot collide with the invoice's paid_at second.
  @backdate_days 14

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
          {:active, fixture} ->
            assert_active_member(fixture, stripe_fixtures.active.subscription_ids)

          {:paused, fixture} ->
            assert_paused_member(fixture)

          {:inactive, fixture} ->
            assert_inactive_member(fixture)

          {:missing, fixture} ->
            assert_inactive_member(fixture)
        end)
      after
        cleanup_stripe_fixtures(stripe_fixtures)
      end
    end
  end

  defp create_stripe_fixtures!(price_ids) do
    run_id = "dhc-stripe-sync-#{System.unique_integer([:positive])}"

    active_customer = create_paying_customer!(run_id, "active")
    active_subscriptions = create_backdated_subscriptions!(active_customer["id"], price_ids)

    paused_customer = create_customer!(run_id, "paused")
    paused_subscriptions = create_send_invoice_subscriptions!(paused_customer["id"], price_ids)
    paused_subscriptions |> List.first() |> Map.fetch!("id") |> pause_subscription!()

    inactive_customer = create_customer!(run_id, "inactive")

    inactive_subscriptions =
      create_send_invoice_subscriptions!(inactive_customer["id"], price_ids)

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

  defp create_send_invoice_subscriptions!(customer_id, price_ids) do
    Enum.map(price_ids, fn price_id ->
      create_subscription!(customer_id, %{
        "items[0][price]" => price_id,
        "collection_method" => "send_invoice",
        "days_until_due" => 30
      })
    end)
  end

  # Creates the active-scenario subscriptions with a backdated start date and
  # automatic collection: Stripe finalizes and charges the first invoice during
  # the create call, so `start_date` is @backdate_days in the past while
  # `latest_invoice.status_transitions.paid_at` is ~now.
  defp create_backdated_subscriptions!(customer_id, price_ids) do
    backdated_start =
      DateTime.utc_now()
      |> DateTime.add(-@backdate_days, :day)
      |> DateTime.truncate(:second)
      |> DateTime.to_unix()

    Enum.map(price_ids, fn price_id ->
      create_subscription!(customer_id, %{
        "items[0][price]" => price_id,
        "collection_method" => "charge_automatically",
        "backdate_start_date" => backdated_start
      })
    end)
  end

  defp create_subscription!(customer_id, params) do
    stripe_request!(:post, "/v1/subscriptions", Map.put(params, "customer", customer_id))
  end

  # Creates the active-scenario customer together with a chargeable test-mode
  # payment method (from tok_visa) set as the invoice default, so subscriptions
  # created for it are charged immediately.
  defp create_paying_customer!(run_id, scenario) do
    payment_method =
      stripe_request!(:post, "/v1/payment_methods", %{
        "type" => "card",
        "card[token]" => "tok_visa"
      })

    base_params = %{
      "name" => "DHC Stripe Sync #{scenario}",
      "email" => "#{run_id}-#{scenario}@example.com",
      "metadata[test_run]" => run_id,
      "metadata[scenario]" => scenario
    }

    stripe_request!(
      :post,
      "/v1/customers",
      base_params
      |> Map.put("payment_method", payment_method["id"])
      |> Map.put("invoice_settings[default_payment_method]", payment_method["id"])
    )
  end

  defp create_customer!(run_id, scenario) do
    stripe_request!(:post, "/v1/customers", %{
      "name" => "DHC Stripe Sync #{scenario}",
      "email" => "#{run_id}-#{scenario}@example.com",
      "metadata[test_run]" => run_id,
      "metadata[scenario]" => scenario
    })
  end

  # Fetches a subscription from the real API with its latest invoice expanded,
  # returning %{paid_at: DateTime.t() | nil, start_date: DateTime.t()}.
  defp fetch_subscription_dates!(subscription_id) do
    {:ok, subscription} =
      StripeClient.request(
        method: :get,
        url: "/v1/subscriptions/#{subscription_id}",
        query: [{"expand[]", "latest_invoice"}]
      )

    paid_at_unix =
      get_in(subscription, ["latest_invoice", "status_transitions", "paid_at"])

    %{
      paid_at: parse_unix(paid_at_unix),
      start_date: parse_unix(subscription["start_date"])
    }
  end

  defp parse_unix(nil), do: nil
  defp parse_unix(unix) when is_integer(unix), do: DateTime.from_unix!(unix)

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

  defp assert_active_member(fixture, subscription_ids) do
    assert %{is_active: true} = user_profile(fixture)

    member = member_profile(fixture)
    assert is_nil(member.subscription_paused_until)

    # Last payment date contract: it must be one of the subscriptions' latest
    # invoice paid_at timestamps — never a backdated subscription start_date.
    dates = Enum.map(subscription_ids, &fetch_subscription_dates!/1)
    paid_ats = dates |> Enum.map(& &1.paid_at) |> Enum.reject(&is_nil/1)
    start_dates = Enum.map(dates, & &1.start_date)

    assert member.last_payment_date in paid_ats,
           "expected last_payment_date #{inspect(member.last_payment_date)} to be one of " <>
             "the latest invoices' paid_at values #{inspect(paid_ats)}"

    refute member.last_payment_date in start_dates,
           "last_payment_date fell back to a subscription's start_date " <>
             "(#{inspect(member.last_payment_date)}) instead of the invoice paid_at"
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
