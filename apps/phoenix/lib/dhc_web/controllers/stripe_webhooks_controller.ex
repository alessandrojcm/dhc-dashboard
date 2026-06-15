defmodule DhcWeb.StripeWebhooksController do
  @moduledoc """
  Receives Stripe webhook events, validates the Stripe-Signature header
  using HMAC-SHA256, and enqueues an Oban job for background processing.

  This endpoint is unauthenticated — Stripe sends webhooks without auth tokens.
  Signature verification is the authentication mechanism.

  Returns 200 immediately after validation + enqueue (Stripe requires fast responses).
  Returns 400 for invalid or missing signatures.
  """
  use DhcWeb, :controller

  require Logger

  alias Dhc.Stripe.Webhook, as: StripeWebhook

  @doc """
  POST /api/webhooks/stripe

  Validates the Stripe-Signature header and enqueues the event
  for background processing via Oban.
  """
  def create(conn, _params) do
    # The raw body is cached by DhcWeb.CacheBodyReader in conn.assigns[:raw_body]
    # This is critical: we must verify the signature against the exact bytes
    # Stripe sent, not a re-encoded JSON body.
    payload = conn.assigns[:raw_body]

    if is_nil(payload) or payload == "" do
      Logger.warning("[stripe-webhooks] Empty or missing request body")

      conn
      |> put_status(:bad_request)
      |> put_view(json: DhcWeb.StripeWebhooksJSON)
      |> render(:error, detail: "Missing request body")
    else
      sig_headers = Plug.Conn.get_req_header(conn, "stripe-signature")

      case sig_headers do
        [] ->
          Logger.warning("[stripe-webhooks] Missing Stripe-Signature header")

          conn
          |> put_status(:unauthorized)
          |> put_view(json: DhcWeb.StripeWebhooksJSON)
          |> render(:error, detail: "Missing Stripe-Signature header")

        [sig_header | _] ->
          verify_and_enqueue(conn, payload, sig_header)
      end
    end
  end

  defp verify_and_enqueue(conn, payload, sig_header) do
    secret = StripeWebhook.webhook_secret()

    cond do
      is_nil(secret) or secret == "" ->
        Logger.error("[stripe-webhooks] STRIPE_WEBHOOK_SIGNING_SECRET not configured")

        conn
        |> put_status(:internal_server_error)
        |> put_view(json: DhcWeb.StripeWebhooksJSON)
        |> render(:error, detail: "Webhook secret not configured")

      true ->
        case StripeWebhook.verify(payload, sig_header, secret) do
          {:ok, event} ->
            enqueue_event(conn, event)

          {:error, :no_matching_signature} ->
            Logger.warning("[stripe-webhooks] Invalid signature")

            conn
            |> put_status(:unauthorized)
            |> put_view(json: DhcWeb.StripeWebhooksJSON)
            |> render(:error, detail: "Invalid signature")

          {:error, :timestamp_expired} ->
            Logger.warning("[stripe-webhooks] Timestamp expired")

            conn
            |> put_status(:unauthorized)
            |> put_view(json: DhcWeb.StripeWebhooksJSON)
            |> render(:error, detail: "Timestamp expired")

          {:error, :missing_header} ->
            Logger.warning("[stripe-webhooks] Malformed Stripe-Signature header")

            conn
            |> put_status(:bad_request)
            |> put_view(json: DhcWeb.StripeWebhooksJSON)
            |> render(:error, detail: "Malformed Stripe-Signature header")

          {:error, :invalid_header} ->
            Logger.warning("[stripe-webhooks] Malformed Stripe-Signature header")

            conn
            |> put_status(:bad_request)
            |> put_view(json: DhcWeb.StripeWebhooksJSON)
            |> render(:error, detail: "Malformed Stripe-Signature header")

          {:error, reason} ->
            Logger.warning("[stripe-webhooks] Signature verification failed",
              reason: inspect(reason)
            )

            conn
            |> put_status(:bad_request)
            |> put_view(json: DhcWeb.StripeWebhooksJSON)
            |> render(:error, detail: "Signature verification failed")
        end
    end
  end

  defp enqueue_event(conn, %{"type" => event_type} = event) do
    event_id = Map.get(event, "id", "unknown")

    # Oban.Worker.new/1 returns a changeset; Oban.insert/1 returns the job struct
    changeset =
      Dhc.StripeWebhooks.Worker.new(%{
        "event_type" => event_type,
        "event_id" => event_id,
        "event_data" => event
      })

    case Oban.insert(changeset) do
      {:ok, job} ->
        Logger.info("[stripe-webhooks] Event enqueued",
          event_type: event_type,
          event_id: event_id,
          oban_job_id: job.id
        )

        conn
        |> put_status(:ok)
        |> put_view(json: DhcWeb.StripeWebhooksJSON)
        |> render(:show, %{received: true, event_id: event_id})

      {:error, changeset} ->
        Logger.error("[stripe-webhooks] Failed to enqueue event",
          event_type: event_type,
          event_id: event_id,
          errors: inspect(changeset.errors)
        )

        conn
        |> put_status(:internal_server_error)
        |> put_view(json: DhcWeb.StripeWebhooksJSON)
        |> render(:error, detail: "Failed to enqueue event")
    end
  end

  defp enqueue_event(conn, event) do
    Logger.warning("[stripe-webhooks] Event missing type field: #{inspect(event)}")

    conn
    |> put_status(:bad_request)
    |> put_view(json: DhcWeb.StripeWebhooksJSON)
    |> render(:error, detail: "Missing event type")
  end
end
