defmodule DhcWeb.NotificationsPushJSON do
  @moduledoc false

  alias Dhc.Notifications.PushSubscription

  def render("config.json", %{enabled: enabled, vapid_public_key: key}) do
    %{data: %{enabled: enabled, vapidPublicKey: key}}
  end

  # Deliberately not the row: the endpoint and the browser's keys are the
  # channel's encryption material and never round-trip to any client.
  def render("subscription.json", %{subscription: %PushSubscription{} = subscription}) do
    %{data: %{id: subscription.id, createdAt: subscription.created_at}}
  end

  def render("unsubscribe.json", %{removed: removed}) do
    %{data: %{removed: removed}}
  end

  def render("error.json", %{detail: detail, fields: fields}) do
    %{errors: %{detail: detail, fields: fields}}
  end
end
