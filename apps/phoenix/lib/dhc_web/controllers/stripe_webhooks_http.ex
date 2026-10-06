defmodule DhcWeb.StripeWebhooksHTTP do
  @moduledoc """
  The problem fallback for the Stripe webhook endpoint. Stripe only reads the
  status (2xx acknowledges, anything else is redelivered), so the details are
  for operators reading the Stripe dashboard's delivery log.
  """

  use DhcWeb.Problem,
    reasons: %{
      missing_body: {400, "Missing request body"},
      malformed_signature: {400, "Malformed Stripe-Signature header"},
      verification_failed: {400, "Signature verification failed"},
      missing_event_type: {400, "Missing event type"},
      missing_signature: {401, "Missing Stripe-Signature header"},
      invalid_signature: {401, "Invalid signature"},
      timestamp_expired: {401, "Timestamp expired"},
      secret_not_configured: {500, "Webhook secret not configured"},
      enqueue_failed: {500, "Failed to enqueue event"}
    }
end
