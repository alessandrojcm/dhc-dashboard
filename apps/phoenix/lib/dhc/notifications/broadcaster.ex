defmodule Dhc.Notifications.Broadcaster do
  @moduledoc """
  Best-effort PubSub broadcaster for Notification creation signals.

  This is the single application seam that turns a durably-committed
  Notification row into a realtime invalidation signal. It is intentionally
  best-effort: it returns `:ok | {:error, term()}` and contains failures, so a
  delivery failure cannot turn a successful database write into an
  application error that callers might retry (which would duplicate the row).

  The realtime contract is:

    * topic  — `notifications:<supabase-user-id>` (the notification owner)
    * event  — `notification_created`
    * payload — `%{}` (empty; clients refetch authoritative state over HTTP)

  The broadcaster is resolved at runtime through `Application.get_env/3` so
  tests can substitute a deterministic boundary (mirroring the
  `:auth_verifier` substitution used by HTTP auth tests) without monkey
  patching. The default implementation here calls `Phoenix.PubSub.broadcast/3`
  against the configured `Dhc.PubSub` server.
  """

  require Logger

  alias Dhc.Notifications.Notification

  @type broadcast_result :: :ok | {:error, term()}

  # Substitutes configured via `:notification_broadcaster` must implement this
  # callback. It MUST return `:ok | {:error, term()}` and never raise; the
  # context relies on the error path to log and preserve the committed row.
  @callback broadcast(Notification.t()) :: broadcast_result()

  @doc """
  Broadcasts a `notification_created` signal for the given Notification's
  owner. Returns `:ok` on success and `{:error, reason}` on a PubSub failure;
  callers MUST preserve the committed row regardless of this result.

  Substitutes are configured via `Application.get_env(:dhc, :notification_broadcaster, __MODULE__)`
  and must implement the `Dhc.Notifications.Broadcaster` callback `broadcast/1`.
  """
  @spec notification_created(Notification.t()) :: broadcast_result()
  def notification_created(%Notification{} = notification) do
    result =
      try do
        broadcaster().broadcast(notification)
      rescue
        exception -> {:error, {:exception, exception}}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case result do
      :ok ->
        :ok

      {:error, _reason} = error ->
        log_failure(notification, error)
        error

      other ->
        error = {:error, {:invalid_broadcast_result, other}}
        log_failure(notification, error)
        error
    end
  end

  defp log_failure(notification, {:error, reason}) do
    Logger.error(
      "[notifications] Broadcast failed for notification #{notification.id} user #{notification.user_id}: #{inspect(reason)}"
    )
  end

  @doc """
  Builds the per-user Notification realtime topic for a Supabase user id.
  """
  @spec topic(String.t()) :: String.t()
  def topic(user_id) when is_binary(user_id), do: "notifications:#{user_id}"

  @doc """
  Default broadcaster implementation: broadcasts an empty-payload
  `notification_created` event to the owner's per-user topic on `Dhc.PubSub`.

  The delivered message is a `Phoenix.Socket.Broadcast`, which joined channels
  forward as the `notification_created` event with an empty payload.
  """
  @spec broadcast(Notification.t()) :: broadcast_result()
  def broadcast(%Notification{user_id: user_id}) do
    DhcWeb.Endpoint.broadcast(topic(user_id), "notification_created", %{})
  end

  defp broadcaster do
    # `nil` is treated as "use the default implementation" so test cleanup that
    # restores the original (absent/nil) value cannot leave the context calling
    # `nil.broadcast/1`.
    Application.get_env(:dhc, :notification_broadcaster, __MODULE__) || __MODULE__
  end
end
