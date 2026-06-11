defmodule Dhc.StripeSync do
  @moduledoc """
  Context module for Stripe membership sync.

  Provides database queries and Stripe API interaction for the
  `Dhc.StripeSync.Worker`. This separation keeps the worker focused on
  job orchestration while the context handles domain logic.
  """

  require Logger

  alias Dhc.StripeSync.Repository

  @membership_lookup_key "standard_membership_fee"
  @price_cache_ttl_hours 24

  @inactive_statuses ~w(canceled incomplete_expired unpaid)

  @type sync_summary :: %{
          target_customers: non_neg_integer(),
          stripe_subscriptions_scanned: non_neg_integer(),
          processed: non_neg_integer(),
          updated: non_neg_integer(),
          failed: non_neg_integer(),
          inactive: non_neg_integer(),
          paused: non_neg_integer(),
          active: non_neg_integer(),
          unchanged: non_neg_integer()
        }

  @type sync_action :: :inactive | :paused | :active | :unchanged

  # ── Target resolution ──────────────────────────────────────────────

  @doc """
  Resolves customer IDs that need syncing.

  If `customer_ids` is provided, those are deduplicated and returned directly.
  Otherwise, queries for members with stale payment data — i.e. whose
  `last_payment_date` is older than 24 hours or null.
  """
  @spec get_target_customer_ids([String.t()] | nil) :: [String.t()]
  def get_target_customer_ids(nil), do: get_stale_customer_ids()
  def get_target_customer_ids([]), do: get_stale_customer_ids()

  def get_target_customer_ids(customer_ids) when is_list(customer_ids) do
    deduped =
      customer_ids
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&(byte_size(&1) > 0))
      |> Enum.uniq()

    Logger.info("[stripe-sync] Using manually provided customer IDs",
      input_count: length(customer_ids),
      target_count: length(deduped)
    )

    deduped
  end

  defp get_stale_customer_ids do
    stale_before = DateTime.add(DateTime.utc_now(), -24, :hour)

    rows = Repository.get_stale_customer_ids(stale_before)

    Logger.info("[stripe-sync] Resolved stale customer IDs",
      target_count: length(rows),
      stale_before: stale_before |> DateTime.to_iso8601()
    )

    rows
  end

  # ── Price ID caching ────────────────────────────────────────────────

  @doc """
  Retrieves the Stripe membership price ID, using a 24-hour cache
  from the `settings` table.

  Returns `{:ok, price_id}` on success, `{:error, reason}` on failure.
  """
  @spec get_membership_price_id() :: {:ok, String.t()} | {:error, term()}
  def get_membership_price_id do
    cached = Repository.fetch_cached_price_id()

    if fresh_cache?(cached) do
      {:ok, cached.value}
    else
      fetch_price_id_from_stripe()
    end
  end

  defp fresh_cache?(nil), do: false

  defp fresh_cache?(%{updated_at: updated_at}) when not is_nil(updated_at) do
    diff_hours = DateTime.diff(DateTime.utc_now(), updated_at, :hour)
    diff_hours <= @price_cache_ttl_hours
  end

  defp fresh_cache?(_), do: false

  defp fetch_price_id_from_stripe do
    case list_stripe_prices() do
      {:ok, [%{"id" => price_id} | _]} ->
        Logger.info("[stripe-sync] Fetched Stripe membership price ID",
          price_id: price_id
        )

        :ok = Repository.upsert_price_id_cache(price_id)
        {:ok, price_id}

      {:ok, []} ->
        Logger.error("[stripe-sync] No Stripe price found for lookup key",
          lookup_key: @membership_lookup_key
        )

        {:error, :price_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Stripe API calls ────────────────────────────────────────────────

  @doc """
  Fetches the latest membership subscription for each target customer
  from the Stripe API.

  Returns `{:ok, %{subscriptions: map(), scanned: non_neg_integer()}}`
  where `subscriptions` maps `customer_id` → most recent subscription,
  or `{:error, reason}`.
  """
  @spec fetch_latest_subscriptions(String.t(), MapSet.t(String.t())) ::
          {:ok, %{subscriptions: %{String.t() => map()}, scanned: non_neg_integer()}}
          | {:error, term()}
  def fetch_latest_subscriptions(price_id, target_customer_ids) do
    Logger.info("[stripe-sync] Fetching Stripe subscriptions for target customers",
      target_customers: MapSet.size(target_customer_ids),
      price_id: price_id
    )

    paginate_subscriptions(price_id, target_customer_ids, %{}, 0, nil)
  end

  defp paginate_subscriptions(price_id, target_customer_ids, acc, scanned, starting_after) do
    params = build_list_params(price_id, starting_after)

    case req_stripe_subscriptions(params) do
      {:ok, %{"data" => data, "has_more" => has_more}} ->
        new_acc =
          Enum.reduce(data, acc, fn sub, inner_acc ->
            customer_id = extract_customer_id(sub)

            if MapSet.member?(target_customer_ids, customer_id) do
              existing = Map.get(inner_acc, customer_id)

              if is_nil(existing) or sub["created"] > existing["created"] do
                Map.put(inner_acc, customer_id, sub)
              else
                inner_acc
              end
            else
              inner_acc
            end
          end)

        new_scanned = scanned + length(data)

        if has_more and data != [] do
          last_id = List.last(data)["id"]
          paginate_subscriptions(price_id, target_customer_ids, new_acc, new_scanned, last_id)
        else
          Logger.info("[stripe-sync] Completed Stripe subscription scan",
            scanned: new_scanned,
            matched_customers: map_size(new_acc)
          )

          {:ok, %{subscriptions: new_acc, scanned: new_scanned}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_list_params(price_id, nil) do
    %{status: "all", price: price_id, limit: 100}
  end

  defp build_list_params(price_id, starting_after) do
    %{status: "all", price: price_id, limit: 100, starting_after: starting_after}
  end

  defp extract_customer_id(%{"customer" => customer}) when is_binary(customer), do: customer

  defp extract_customer_id(%{"customer" => %{"id" => id}}), do: id

  # fallthrough — unlikely but safe
  defp extract_customer_id(_sub), do: nil

  @doc """
  Makes a GET request to the Stripe API to list subscriptions.
  """
  @spec req_stripe_subscriptions(map()) :: {:ok, map()} | {:error, term()}
  def req_stripe_subscriptions(params) do
    stripe_api_url = stripe_api_url()
    stripe_secret_key = stripe_secret_key()

    if is_nil(stripe_secret_key) or stripe_secret_key == "" do
      {:error, :stripe_key_not_configured}
    else
      query_string = URI.encode_query(params)

      case Req.get("#{stripe_api_url}/v1/subscriptions?#{query_string}",
             headers: stripe_headers(stripe_secret_key),
             decode_body: true,
             connect_options: [timeout: 30_000],
             retry: false
           ) do
        {:ok, %Req.Response{status: status, body: body}}
        when status in 200..299 ->
          {:ok, body}

        {:ok, %Req.Response{status: status, body: body}} ->
          Logger.error("[stripe-sync] Stripe API returned #{status}",
            status: status,
            body: inspect(body)
          )

          {:error, {:stripe_api, status}}

        {:error, exception} ->
          Logger.error("[stripe-sync] Stripe HTTP request failed: #{inspect(exception)}")
          {:error, {:http_error, exception}}
      end
    end
  end

  @doc """
  Makes a GET request to the Stripe API to list prices.
  """
  @spec req_stripe_prices(map()) :: {:ok, map()} | {:error, term()}
  def req_stripe_prices(params) do
    stripe_api_url = stripe_api_url()
    stripe_secret_key = stripe_secret_key()

    if is_nil(stripe_secret_key) or stripe_secret_key == "" do
      {:error, :stripe_key_not_configured}
    else
      query_string = URI.encode_query(params)

      case Req.get("#{stripe_api_url}/v1/prices?#{query_string}",
             headers: stripe_headers(stripe_secret_key),
             decode_body: true,
             connect_options: [timeout: 30_000],
             retry: false
           ) do
        {:ok, %Req.Response{status: status, body: body}}
        when status in 200..299 ->
          {:ok, body}

        {:ok, %Req.Response{status: status, body: body}} ->
          Logger.error("[stripe-sync] Stripe prices API returned #{status}",
            status: status,
            body: inspect(body)
          )

          {:error, {:stripe_api, status}}

        {:error, exception} ->
          Logger.error("[stripe-sync] Stripe prices HTTP request failed: #{inspect(exception)}")
          {:error, {:http_error, exception}}
      end
    end
  end

  defp list_stripe_prices do
    params = %{lookup_keys: @membership_lookup_key, active: "true", limit: 1}

    case req_stripe_prices(params) do
      {:ok, %{"data" => data}} ->
        {:ok, data}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Customer sync ───────────────────────────────────────────────────

  @doc """
  Syncs a single customer's membership status against their Stripe subscription.

  Returns `{:ok, action}` where action is `:inactive`, `:paused`, `:active`,
  or `:unchanged`. Returns `{:error, reason}` if the database write fails.
  """
  @spec sync_customer(String.t(), map() | nil) :: {:ok, sync_action()} | {:error, term()}
  def sync_customer(customer_id, nil) do
    mark_inactive(customer_id)
  end

  def sync_customer(customer_id, %{"status" => status} = subscription) do
    cond do
      status in @inactive_statuses ->
        mark_inactive(customer_id)

      Map.get(subscription, "pause_collection") != nil ->
        mark_paused(customer_id, subscription)

      status == "active" ->
        mark_active(customer_id, subscription)

      true ->
        Logger.debug("[stripe-sync] No customer updates applied",
          customer_id: customer_id,
          subscription_status: status
        )

        {:ok, :unchanged}
    end
  end

  defp mark_inactive(customer_id) do
    try do
      :ok = Repository.mark_customer_inactive(customer_id)

      Logger.debug("[stripe-sync] Marked customer inactive",
        customer_id: customer_id
      )

      {:ok, :inactive}
    rescue
      e ->
        Logger.error("[stripe-sync] Failed to mark customer inactive",
          customer_id: customer_id,
          error: inspect(e)
        )

        {:error, {:db_error, e}}
    end
  end

  defp mark_paused(customer_id, subscription) do
    pause_collection = Map.get(subscription, "pause_collection", %{})
    resumes_at = Map.get(pause_collection, "resumes_at")
    resume_date = parse_unix_timestamp(resumes_at)

    try do
      :ok = Repository.mark_customer_paused(customer_id, resume_date)

      Logger.debug("[stripe-sync] Marked customer as paused",
        customer_id: customer_id,
        resume_date: if(resume_date, do: DateTime.to_iso8601(resume_date), else: nil)
      )

      {:ok, :paused}
    rescue
      e ->
        Logger.error("[stripe-sync] Failed to mark customer as paused",
          customer_id: customer_id,
          error: inspect(e)
        )

        {:error, {:db_error, e}}
    end
  end

  defp mark_active(customer_id, subscription) do
    last_payment_date = resolve_last_payment_date(subscription)
    ended_at = parse_unix_timestamp(Map.get(subscription, "ended_at"))

    try do
      :ok = Repository.mark_customer_active(customer_id, last_payment_date, ended_at)

      Logger.debug("[stripe-sync] Marked customer as active",
        customer_id: customer_id,
        last_payment_date:
          if(last_payment_date, do: DateTime.to_iso8601(last_payment_date), else: nil)
      )

      {:ok, :active}
    rescue
      e ->
        Logger.error("[stripe-sync] Failed to mark customer as active",
          customer_id: customer_id,
          error: inspect(e)
        )

        {:error, {:db_error, e}}
    end
  end

  @doc """
  Resolves the last payment date from a Stripe subscription.

  Uses the latest invoice's `paid_at` timestamp, falling back to
  the subscription's `start_date` when unavailable.
  """
  @spec resolve_last_payment_date(map()) :: DateTime.t() | nil
  def resolve_last_payment_date(subscription) do
    latest_invoice = Map.get(subscription, "latest_invoice")
    paid_at = safe_get_in(latest_invoice, ["status_transitions", "paid_at"])
    start_date = Map.get(subscription, "start_date")

    cond do
      is_number(paid_at) -> DateTime.from_unix!(paid_at)
      is_number(start_date) -> DateTime.from_unix!(start_date)
      true -> nil
    end
  end

  # get_in/2 crashes on non-nestable values (strings, numbers).
  # This wrapper returns nil for anything that isn't a map or list.
  defp safe_get_in(value, path) when is_map(value) or is_list(value), do: get_in(value, path)
  defp safe_get_in(_value, _path), do: nil

  defp parse_unix_timestamp(nil), do: nil

  defp parse_unix_timestamp(timestamp) when is_number(timestamp) do
    DateTime.from_unix!(timestamp)
  end

  defp parse_unix_timestamp(_), do: nil

  # ── Full batch sync ─────────────────────────────────────────────────

  @doc """
  Runs the full Stripe sync batch process.

  1. Resolves target customer IDs (stale members or manual override)
  2. Fetches the membership price ID (with caching)
  3. Fetches latest subscriptions from Stripe
  4. Syncs each customer individually
  5. Returns a summary of outcomes
  """
  @spec run_sync([String.t()] | nil) :: {:ok, sync_summary()} | {:error, term()}
  def run_sync(customer_ids \\ nil) do
    Logger.info("[stripe-sync] Starting stripe sync batch",
      manual_customer_ids_provided: customer_ids != nil and customer_ids != [],
      manual_customer_count: if(customer_ids, do: length(customer_ids), else: 0)
    )

    with target_ids <- get_target_customer_ids(customer_ids),
         :ok <- verify_targets(target_ids),
         {:ok, price_id} <- get_membership_price_id(),
         target_set <- MapSet.new(target_ids),
         {:ok, %{subscriptions: subscriptions, scanned: scanned}} <-
           fetch_latest_subscriptions(price_id, target_set) do
      summary = sync_all_customers(target_ids, subscriptions, scanned)
      {:ok, summary}
    else
      {:error, reason} = error ->
        Logger.error("[stripe-sync] Batch sync failed: #{inspect(reason)}")
        Sentry.capture_exception(reason)
        error
    end
  end

  defp verify_targets([]) do
    Logger.info("[stripe-sync] No target customers found for sync")
    {:ok, :no_targets}
  end

  defp verify_targets(_), do: :ok

  defp sync_all_customers(target_ids, subscriptions, scanned) do
    initial_summary = %{
      target_customers: length(target_ids),
      stripe_subscriptions_scanned: scanned,
      processed: 0,
      updated: 0,
      failed: 0,
      inactive: 0,
      paused: 0,
      active: 0,
      unchanged: 0
    }

    summary =
      Enum.reduce(target_ids, initial_summary, fn customer_id, acc ->
        sub = Map.get(subscriptions, customer_id)

        case sync_customer(customer_id, sub) do
          {:ok, action} when action in [:inactive, :paused, :active] ->
            %{acc | processed: acc.processed + 1, updated: acc.updated + 1}
            |> Map.update!(action, &(&1 + 1))

          {:ok, :unchanged} ->
            %{acc | processed: acc.processed + 1, unchanged: acc.unchanged + 1}

          {:error, reason} ->
            Logger.error(
              "[stripe-sync] Error syncing customer #{customer_id}: #{inspect(reason)}",
              customer_id: customer_id
            )

            Sentry.capture_message("Error syncing Stripe data for customer",
              level: :error,
              extra: %{customer_id: customer_id, reason: inspect(reason)}
            )

            %{acc | processed: acc.processed + 1, failed: acc.failed + 1}
        end
      end)

    Logger.info("[stripe-sync] Completed stripe sync batch",
      target_customers: summary.target_customers,
      stripe_subscriptions_scanned: summary.stripe_subscriptions_scanned,
      processed: summary.processed,
      updated: summary.updated,
      failed: summary.failed,
      inactive: summary.inactive,
      paused: summary.paused,
      active: summary.active,
      unchanged: summary.unchanged
    )

    summary
  end

  # ── Config accessors ────────────────────────────────────────────────

  @doc """
  Returns the Stripe API base URL, overridable in tests via app config.
  """
  @spec stripe_api_url() :: String.t()
  def stripe_api_url do
    Application.get_env(:dhc, :stripe_api_url, "https://api.stripe.com")
  end

  @doc """
  Returns the Stripe API version, pinned to match the Deno edge functions.
  """
  @spec stripe_api_version() :: String.t()
  def stripe_api_version do
    Application.get_env(:dhc, :stripe_api_version, "2025-10-29.clover")
  end

  @doc """
  Returns the Stripe secret key from app config.
  """
  @spec stripe_secret_key() :: String.t() | nil
  def stripe_secret_key do
    Application.get_env(:dhc, :stripe_secret_key)
  end

  defp stripe_headers(secret_key) do
    [
      {"authorization", "Bearer #{secret_key}"},
      {"stripe-version", stripe_api_version()},
      {"content-type", "application/x-www-form-urlencoded"}
    ]
  end
end
