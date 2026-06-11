defmodule Dhc.StripeSync.Worker do
  @moduledoc """
  Oban worker that synchronizes Stripe membership data into the database.

  Migrated from the `stripe-sync` Deno edge function (triggered by pg_cron).
  Each job resolves stale members or a specific set of customer IDs, fetches
  their latest subscription status from Stripe, and updates membership records.

  ## Job args

    * `customer_ids` — optional list of Stripe customer IDs for targeted re-sync.
      When omitted, the worker queries for all members with stale payment data
      (no recent sync timestamp / payment date older than 24 hours).

  ## Cron schedule

  Registered as an `Oban.Cron` job running daily at midnight UTC (`0 0 * * *`).

  ## Environment behaviour

    * **dev/test** — Stripe API calls are skipped; the worker logs and returns `:ok`
    * **prod** — calls Stripe API via `Req` to fetch subscription data

  Oban handles retries with exponential backoff. If the Stripe API returns
  a non-2xx response, the job returns `{:error, reason}` and will be retried
  up to `max_attempts` times.
  """

  use Oban.Worker, queue: :stripe, max_attempts: 3

  require Logger

  alias Dhc.StripeSync

  @impl Worker
  def perform(%Oban.Job{args: args}) do
    with :ok <- validate_args(args),
         customer_ids <- parse_customer_ids(args),
         {:ok, result} <- run_sync(customer_ids) do
      case result do
        :no_targets ->
          Logger.info("[stripe-sync-worker] No targets to sync")
          :ok

        summary ->
          Logger.info("[stripe-sync-worker] Sync complete",
            target_customers: summary.target_customers,
            processed: summary.processed,
            updated: summary.updated,
            failed: summary.failed
          )

          :ok
      end
    else
      {:error, reason} = error ->
        Logger.error("[stripe-sync-worker] Job failed: #{inspect(reason)}")
        error
    end
  end

  defp validate_args(args) do
    errors =
      []
      |> validate_customer_ids(args)

    case errors do
      [] ->
        :ok

      errors ->
        message = "Invalid stripe-sync job args: #{Enum.join(errors, ", ")}"
        Sentry.capture_message(message, level: :error, extra: %{args: args})
        {:error, {:validation, errors}}
    end
  end

  defp validate_customer_ids(errors, %{"customer_ids" => ids}) when is_list(ids) do
    if Enum.all?(ids, &is_binary/1) do
      errors
    else
      ["customer_ids must contain only strings" | errors]
    end
  end

  defp validate_customer_ids(errors, %{"customer_ids" => _}) do
    ["customer_ids must be an array" | errors]
  end

  defp validate_customer_ids(errors, _args), do: errors

  defp parse_customer_ids(%{"customer_ids" => ids}) when is_list(ids) and ids != [] do
    ids
  end

  defp parse_customer_ids(_args), do: nil

  defp run_sync(customer_ids) do
    StripeSync.run_sync(customer_ids)
  end
end
