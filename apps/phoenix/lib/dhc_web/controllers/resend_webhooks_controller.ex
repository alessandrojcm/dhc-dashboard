defmodule DhcWeb.ResendWebhooksController do
  @moduledoc """
  Receives Resend webhook deliveries (ALE-409). Only `email.received` is
  handled: a reply to an Intake Reply address, which is recorded and queued
  for forwarding by `Dhc.BeginnersWorkshops.IntakeReplies.record_received/2`.
  Every other event type is acknowledged with 200 and ignored.

  Unauthenticated: the Svix signature over the raw body (cached by
  `DhcWeb.CacheBodyReader`) is the authentication, verified with
  `RESEND_WEBHOOK_SIGNING_SECRET` by `Dhc.Resend.Webhook`. A stale timestamp
  is refused.

  With Intake Replies parked (`IntakeReplies.enabled?/0` off, ALE-414) the
  signature is still verified and the delivery is still acknowledged, but
  nothing is recorded: `handled` is `false`. No reply address is minted while
  the feature is off, so no reply can be dropped by this.

  The payload's `to` holds reply addresses, which are credentials, so it is
  never logged: the route is `log: false` (no router "Parameters" line) and
  `DhcWeb.IntakeLinkPrivacy.scrub_body/1` keeps it out of Sentry.
  """
  use DhcWeb, :controller

  require Logger

  alias Dhc.BeginnersWorkshops.IntakeReplies
  alias Dhc.Resend.Webhook

  action_fallback DhcWeb.ResendWebhooksHTTP

  @doc "POST /api/webhooks/resend"
  def create(conn, _params) do
    with {:ok, payload} <- fetch_payload(conn),
         {:ok, secret} <- fetch_secret(),
         {:ok, event} <- verify(conn, payload, secret),
         {:ok, handled} <- handle(event) do
      conn
      |> put_view(json: DhcWeb.ResendWebhooksJSON)
      |> render(:show, %{received: true, handled: handled})
    end
  end

  defp fetch_payload(conn) do
    case conn.assigns[:raw_body] do
      payload when is_binary(payload) and payload != "" -> {:ok, payload}
      _missing -> {:error, :missing_body}
    end
  end

  defp fetch_secret do
    case Webhook.webhook_secret() do
      secret when secret in [nil, "", []] ->
        Logger.error("[resend-webhooks] RESEND_WEBHOOK_SIGNING_SECRET not configured")
        {:error, :secret_not_configured}

      secret ->
        {:ok, secret}
    end
  end

  defp verify(conn, payload, secret) do
    headers = %{
      id: header(conn, "svix-id"),
      timestamp: header(conn, "svix-timestamp"),
      signature: header(conn, "svix-signature")
    }

    case Webhook.verify(payload, headers, secret) do
      {:ok, event} ->
        {:ok, event}

      {:error, reason} ->
        Logger.warning("[resend-webhooks] Delivery refused", reason: reason)
        {:error, refusal(reason)}
    end
  end

  defp refusal(:missing_header), do: :missing_signature
  defp refusal(:invalid_header), do: :malformed_signature
  defp refusal(:timestamp_expired), do: :timestamp_expired
  defp refusal(:no_matching_signature), do: :invalid_signature
  defp refusal(:invalid_payload), do: :invalid_payload

  defp header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp handle(%{"type" => "email.received", "data" => %{} = data}) do
    if IntakeReplies.enabled?() do
      case IntakeReplies.record_received(data) do
        {:ok, _recorded_or_duplicate} -> {:ok, true}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, false}
    end
  end

  defp handle(%{"type" => "email.received"}), do: {:error, :invalid_payload}
  defp handle(%{"type" => type}) when is_binary(type), do: {:ok, false}
  defp handle(_event), do: {:error, :invalid_payload}
end
