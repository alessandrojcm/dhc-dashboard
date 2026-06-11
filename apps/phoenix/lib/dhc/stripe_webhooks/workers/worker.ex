defmodule Dhc.StripeWebhooks.Worker do
  @moduledoc """
  Oban worker that processes Stripe webhook events in the background.

  Enqueued by `DhcWeb.StripeWebhooksController` after signature verification.
  Each job processes a single Stripe event based on its type:

    * **Charge events** — confirm or cancel workshop registrations
    * **Subscription events** — sync membership status via `Dhc.StripeSync`
    * **Invoice / payment intent events** — sync customer data

  ## Job args

    * `event_type` — Stripe event type string (e.g. `"charge.succeeded"`)
    * `event_id` — Stripe event ID (for idempotency / logging)
    * `event_data` — the full Stripe event payload as a map

  ## Retry policy

  Uses the `stripe` queue with `max_attempts: 3` and exponential backoff,
  consistent with `Dhc.StripeSync.Worker`.
  """

  use Oban.Worker, queue: :stripe, max_attempts: 3

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
