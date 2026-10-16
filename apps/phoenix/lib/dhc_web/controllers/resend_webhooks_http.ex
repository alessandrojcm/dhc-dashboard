defmodule DhcWeb.ResendWebhooksHTTP do
  @moduledoc """
  The problem fallback for the Resend webhook endpoint (ALE-409). Resend only
  reads the status (2xx acknowledges, anything else is retried), so the
  details are for operators reading Resend's delivery log.
  """

  use DhcWeb.Problem,
    reasons: %{
      missing_body: {400, "Missing request body"},
      malformed_signature: {400, "Malformed Svix signature headers"},
      invalid_payload: {400, "Invalid webhook payload"},
      missing_signature: {401, "Missing Svix signature headers"},
      invalid_signature: {401, "Invalid signature"},
      timestamp_expired: {401, "Timestamp outside the tolerance"},
      secret_not_configured: {500, "Webhook secret not configured"},
      enqueue_failed: {500, "Failed to enqueue the reply"}
    }
end
