defmodule DhcWeb.NotificationsHTTP do
  @moduledoc "The problem fallback for the Notifications and Notifications Push HTTP slices."

  use DhcWeb.Problem,
    reasons: %{
      not_found: {404, "Notification not found"},
      invalid_query: {400, "Invalid notifications query"},
      endpoint_required: {422, "endpoint is required"}
    },
    fields: %{
      endpoint: "endpoint",
      p256dh: "p256dh",
      auth: "auth",
      user_agent: "userAgent"
    }
end
