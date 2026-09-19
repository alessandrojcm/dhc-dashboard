defmodule DhcWeb.NotificationsPushController do
  @moduledoc """
  ALE-299: the `notificationsPush` slice — Web Push registration for the
  notification centre.

  Everything here is scoped to the authenticated principal and discloses as
  little as possible: `config` returns the VAPID *public* key, `subscribe`
  returns the stored row's id and timestamp, `unsubscribe` returns whether a
  row was removed. Endpoints, browser keys, and the VAPID private key never
  appear in a response.
  """

  use DhcWeb, :controller

  alias Dhc.Notifications.WebPush

  @doc "GET /notifications/push/config"
  def config(conn, _params) do
    conn
    |> put_view(json: DhcWeb.NotificationsPushJSON)
    |> render(:config, enabled: WebPush.enabled?(), vapid_public_key: WebPush.vapid_public_key())
  end

  @doc "POST /notifications/push/subscriptions"
  def subscribe(conn, params) do
    principal_id = conn.assigns.current_session.principal.id

    case WebPush.subscribe(principal_id, subscribe_attrs(params)) do
      {:ok, subscription} ->
        conn
        |> put_status(:created)
        |> put_view(json: DhcWeb.NotificationsPushJSON)
        |> render(:subscription, subscription: subscription)

      {:error, %Ecto.Changeset{} = changeset} ->
        unprocessable(conn, changeset)
    end
  end

  @doc "POST /notifications/push/unsubscribe"
  def unsubscribe(conn, %{"endpoint" => endpoint}) when is_binary(endpoint) and endpoint != "" do
    principal_id = conn.assigns.current_session.principal.id
    {:ok, outcome} = WebPush.unsubscribe(principal_id, endpoint)

    conn
    |> put_view(json: DhcWeb.NotificationsPushJSON)
    |> render(:unsubscribe, removed: outcome == :removed)
  end

  def unsubscribe(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: DhcWeb.NotificationsPushJSON)
    |> render(:error, detail: "endpoint is required", fields: %{"endpoint" => ["is required"]})
  end

  # The body is `PushSubscription.toJSON()` (endpoint + nested keys) plus an
  # optional label; flatten it into the context's attrs. Missing pieces become
  # `nil` so the changeset reports them as required fields rather than the
  # controller pattern-matching them into a 400.
  defp subscribe_attrs(params) do
    keys = Map.get(params, "keys") || %{}

    %{
      endpoint: Map.get(params, "endpoint"),
      p256dh: if(is_map(keys), do: Map.get(keys, "p256dh")),
      auth: if(is_map(keys), do: Map.get(keys, "auth")),
      user_agent: Map.get(params, "userAgent")
    }
  end

  defp unprocessable(conn, %Ecto.Changeset{} = changeset) do
    fields = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)

    detail =
      Enum.map_join(fields, "; ", fn {field, messages} ->
        "#{field} #{Enum.join(List.wrap(messages), ", ")}"
      end)

    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: DhcWeb.NotificationsPushJSON)
    |> render(:error, detail: detail, fields: fields)
  end
end
