defmodule Dhc.StripeWebhooks.Worker do
  @moduledoc """
  Oban worker that processes Stripe webhook events in the background.

  Enqueued by `DhcWeb.StripeWebhooksController` after signature verification.
  Each job hands a single Stripe event to `Dhc.StripeWebhooks.process_event/1`,
  which routes it to the domain reconcile functions in its routing table.

  ## Job args

    * `event_type` — Stripe event type string (e.g. `"invoice.paid"`)
    * `event_id` — Stripe event ID (for idempotency / logging)
    * `event_data` — the full Stripe event payload as a map

  ## Retry policy

  Uses the `stripe` queue with `max_attempts: 3` and exponential backoff,
  consistent with `Dhc.StripeSync.Worker`. A retry re-runs every target of the
  event, which is why each routed reconcile function must be idempotent.

  ## Deduplication

  Jobs are unique on `event_id` for 24 hours across all job states, so a
  Stripe redelivery of an event already enqueued (or already processed) in that
  window inserts no second job. That includes `discarded` jobs: an event whose
  job was discarded after 3 attempts cannot be replayed by re-sending it from
  Stripe within the window; retry the discarded job instead (see the replay
  note beside the routing table in `Dhc.StripeWebhooks`).
  """

  use Oban.Worker,
    queue: :stripe,
    max_attempts: 3,
    unique: [keys: [:event_id], period: 86_400, states: :all]

  require Logger

  alias Dhc.StripeWebhooks

  @impl Worker
  def perform(%Oban.Job{args: %{"event_type" => event_type, "event_id" => event_id} = args}) do
    event_data = Map.get(args, "event_data", %{})

    Logger.info("[stripe-webhooks-worker] Processing event",
      event_type: event_type,
      event_id: event_id
    )

    case StripeWebhooks.process_event(event_data) do
      :ok ->
        Logger.info("[stripe-webhooks-worker] Event processed successfully",
          event_type: event_type,
          event_id: event_id
        )

        :ok

      {:error, reason} ->
        Logger.error("[stripe-webhooks-worker] Event processing failed",
          event_type: event_type,
          event_id: event_id,
          reason: inspect(reason)
        )

        Sentry.capture_message("Stripe webhook processing failed",
          level: :error,
          extra: %{event_type: event_type, event_id: event_id, reason: inspect(reason)}
        )

        {:error, reason}
    end
  end

  @impl Worker
  def perform(%Oban.Job{args: args}) do
    Logger.error("[stripe-webhooks-worker] Invalid job args: #{inspect(args)}")

    Sentry.capture_message("Stripe webhook worker received invalid args",
      level: :error,
      extra: %{args: args}
    )

    {:error, :invalid_args}
  end
end
