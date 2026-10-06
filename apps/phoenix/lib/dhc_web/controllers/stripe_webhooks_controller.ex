defmodule DhcWeb.StripeWebhooksController do
  @moduledoc """
  Receives Stripe webhook events, validates the Stripe-Signature header
  using HMAC-SHA256, and enqueues an Oban job for background processing.

  This endpoint is unauthenticated — Stripe sends webhooks without auth tokens.
  Signature verification is the authentication mechanism.

  Returns 200 immediately after validation + enqueue (Stripe requires fast
  responses). Every refusal is a `DhcWeb.StripeWebhooksHTTP` reason.
  """
  use DhcWeb, :controller

  require Logger

  alias Dhc.Stripe.Webhook, as: StripeWebhook

  action_fallback DhcWeb.StripeWebhooksHTTP

  @doc """
  POST /api/webhooks/stripe

  Validates the Stripe-Signature header and enqueues the event
  for background processing via Oban.
  """
  def create(conn, _params) do
    # The raw body is cached by DhcWeb.CacheBodyReader in conn.assigns[:raw_body].
    # The signature must be verified against the exact bytes Stripe sent, not
    # a re-encoded JSON body.
    with {:ok, payload} <- fetch_payload(conn),
         {:ok, sig_header} <- fetch_signature(conn),
         {:ok, secret} <- fetch_secret(),
         {:ok, event} <- verify(payload, sig_header, secret),
         {:ok, event_id} <- enqueue(event) do
      conn
      |> put_view(json: DhcWeb.StripeWebhooksJSON)
      |> render(:show, %{received: true, event_id: event_id})
    end
  end

  defp fetch_payload(conn) do
    case conn.assigns[:raw_body] do
      payload when is_binary(payload) and payload != "" ->
        {:ok, payload}

      _ ->
        Logger.warning("[stripe-webhooks] Empty or missing request body")
        {:error, :missing_body}
    end
  end

  defp fetch_signature(conn) do
    case Plug.Conn.get_req_header(conn, "stripe-signature") do
      [sig_header | _] ->
        {:ok, sig_header}

      [] ->
        Logger.warning("[stripe-webhooks] Missing Stripe-Signature header")
        {:error, :missing_signature}
    end
  end

  # A list is several active secrets during a rotation.
  defp fetch_secret do
    case StripeWebhook.webhook_secret() do
      secret when secret in [nil, "", []] ->
        Logger.error("[stripe-webhooks] STRIPE_WEBHOOK_SIGNING_SECRET not configured")
        {:error, :secret_not_configured}

      secret ->
        {:ok, secret}
    end
  end

  defp verify(payload, sig_header, secret) do
    case StripeWebhook.verify(payload, sig_header, secret) do
      {:ok, event} ->
        {:ok, event}

      {:error, :no_matching_signature} ->
        Logger.warning("[stripe-webhooks] Invalid signature")
        {:error, :invalid_signature}

      {:error, :timestamp_expired} ->
        Logger.warning("[stripe-webhooks] Timestamp expired")
        {:error, :timestamp_expired}

      {:error, reason} when reason in [:missing_header, :invalid_header] ->
        Logger.warning("[stripe-webhooks] Malformed Stripe-Signature header")
        {:error, :malformed_signature}

      {:error, reason} ->
        Logger.warning("[stripe-webhooks] Signature verification failed",
          reason: inspect(reason)
        )

        {:error, :verification_failed}
    end
  end

  defp enqueue(%{"type" => event_type} = event) do
    event_id = Map.get(event, "id", "unknown")

    %{"event_type" => event_type, "event_id" => event_id, "event_data" => event}
    |> Dhc.StripeWebhooks.Worker.new()
    |> Oban.insert()
    |> case do
      {:ok, job} ->
        Logger.info("[stripe-webhooks] Event enqueued",
          event_type: event_type,
          event_id: event_id,
          oban_job_id: job.id
        )

        {:ok, event_id}

      {:error, changeset} ->
        Logger.error("[stripe-webhooks] Failed to enqueue event",
          event_type: event_type,
          event_id: event_id,
          errors: inspect(changeset.errors)
        )

        {:error, :enqueue_failed}
    end
  end

  defp enqueue(event) do
    Logger.warning("[stripe-webhooks] Event missing type field: #{inspect(event)}")
    {:error, :missing_event_type}
  end
end
