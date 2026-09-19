defmodule Dhc.Notifications.WebPush do
  @moduledoc """
  ALE-299: Web Push as an additional, best-effort delivery channel for the
  notification centre.

  The notification row stays the source of truth. Push is fanned out *after*
  the row is committed (see `Dhc.Notifications` post-commit signalling), one
  Oban job per notification, and nothing on this path can roll back, fail, or
  duplicate the row: a dead subscription is removed, a transient failure is
  counted and logged, and the job succeeds either way.

  Subscriptions are **per browser installation**, not per member. The push
  service mints one endpoint per browser, so the endpoint is the identity:
  re-registering it refreshes the keys, and registering it under another
  signed-in principal reassigns it (that browser can only ever be delivering
  for whoever is signed in). A member with a phone PWA and a laptop browser has
  two rows that live and die independently.

  What the API may disclose is `id` and `createdAt`. The endpoint URL and the
  `p256dh`/`auth` encryption material never leave the server, and the VAPID
  private key is read by `web_push_ex` from application config and is not
  reachable through this module.
  """

  import Ecto.Query

  require Logger

  alias Dhc.Notifications.Notification
  alias Dhc.Notifications.PushSubscription
  alias Dhc.Notifications.WebPush.HttpSender
  alias Dhc.Notifications.Workers.WebPushWorker
  alias Dhc.Repo

  @type subscribe_attrs :: %{
          required(:endpoint) => String.t(),
          required(:p256dh) => String.t(),
          required(:auth) => String.t(),
          optional(:user_agent) => String.t() | nil
        }

  @type delivery_report :: %{
          sent: non_neg_integer(),
          removed: non_neg_integer(),
          failed: non_neg_integer()
        }

  @title "Dublin HEMA Club"

  # Uncompressed P-256 point: 0x04 || X (32) || Y (32).
  @p256dh_bytes 65
  @auth_bytes 16

  ## Configuration

  @doc """
  Whether a VAPID key pair is configured. When it is not, subscriptions can
  still be registered but nothing is enqueued, and the API tells clients push
  is unavailable rather than handing them a `null` application server key.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: vapid_public_key() != nil

  @doc "The VAPID public key browsers pass as `applicationServerKey`, or `nil`."
  @spec vapid_public_key() :: String.t() | nil
  def vapid_public_key do
    vapid = Application.get_env(:web_push_ex, :vapid) || []

    with public when is_binary(public) and public != "" <- Keyword.get(vapid, :public_key),
         private when is_binary(private) and private != "" <- Keyword.get(vapid, :private_key),
         subject when is_binary(subject) and subject != "" <- Keyword.get(vapid, :subject) do
      public
    else
      _ -> nil
    end
  end

  ## Subscriptions

  @doc """
  Registers (or refreshes) the browser subscription for `principal_id`.

  Upserts on the endpoint: the same browser re-subscribing gets its keys
  refreshed in place, and an endpoint last registered by a different principal
  is reassigned. Returns the stored row; callers must not render its
  `endpoint`, `p256dh`, or `auth`.
  """
  @spec subscribe(String.t(), subscribe_attrs()) ::
          {:ok, PushSubscription.t()} | {:error, Ecto.Changeset.t()}
  def subscribe(principal_id, attrs) when is_binary(principal_id) and is_map(attrs) do
    principal_id
    |> subscription_changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:principal_id, :p256dh, :auth, :user_agent, :updated_at]},
      conflict_target: :endpoint,
      returning: true
    )
  end

  @doc """
  Removes the caller's subscription for `endpoint`. Scoped to the principal so a
  member cannot silence another member's device by guessing an endpoint;
  idempotent because the browser may already have dropped its side.
  """
  @spec unsubscribe(String.t(), String.t()) :: {:ok, :removed | :not_found}
  def unsubscribe(principal_id, endpoint) when is_binary(principal_id) and is_binary(endpoint) do
    {deleted, _} =
      PushSubscription
      |> where([s], s.principal_id == ^principal_id and s.endpoint == ^endpoint)
      |> Repo.delete_all()

    if deleted > 0, do: {:ok, :removed}, else: {:ok, :not_found}
  end

  @doc "Every browser installation registered for the principal, oldest first."
  @spec list_for_principal(String.t()) :: [PushSubscription.t()]
  def list_for_principal(principal_id) when is_binary(principal_id) do
    PushSubscription
    |> where([s], s.principal_id == ^principal_id)
    |> order_by([s], asc: s.created_at, asc: s.id)
    |> Repo.all()
  end

  ## Delivery

  @doc """
  Best-effort: schedules push delivery for a committed notification.

  Called by `Dhc.Notifications` after the row is durable. Never raises and
  always returns `:ok` — an enqueue failure is logged and the notification
  stands, exactly like a failed PubSub broadcast. Enqueues nothing when VAPID
  is not configured, so an environment without keys pays no job per
  notification.
  """
  @spec enqueue_delivery(Notification.t()) :: :ok
  def enqueue_delivery(%Notification{id: id, principal_id: principal_id}) do
    if enabled?() do
      case %{notification_id: id} |> WebPushWorker.new() |> Oban.insert() do
        {:ok, _job} ->
          :ok

        {:error, reason} ->
          log_enqueue_failure(id, principal_id, reason)
      end
    else
      :ok
    end
  rescue
    exception -> log_enqueue_failure(id, principal_id, {:exception, exception})
  catch
    kind, reason -> log_enqueue_failure(id, principal_id, {kind, reason})
  end

  @doc """
  Pushes one notification to every browser of its recipient.

  Each subscription is attempted once. A `{:error, :gone}` (404/410) deletes
  that subscription; any other error is counted as `failed` and logged with
  the subscription id, never with the endpoint or keys. Never raises.
  """
  @spec deliver(Notification.t()) :: delivery_report()
  def deliver(%Notification{} = notification) do
    payload = payload(notification)

    notification.principal_id
    |> list_for_principal()
    |> Enum.reduce(%{sent: 0, removed: 0, failed: 0}, fn subscription, report ->
      case attempt(subscription, payload) do
        :ok ->
          %{report | sent: report.sent + 1}

        {:error, :gone} ->
          remove_gone(subscription)
          %{report | removed: report.removed + 1}

        {:error, reason} ->
          Logger.warning(
            "[web-push] Delivery failed for notification #{notification.id} subscription #{subscription.id}: #{inspect(reason)}"
          )

          %{report | failed: report.failed + 1}
      end
    end)
  end

  @doc """
  The payload a browser's service worker displays. `tag` is the notification id
  so a re-sent push replaces rather than stacks; `url` is where a click lands.
  """
  @spec payload(Notification.t()) :: map()
  def payload(%Notification{} = notification) do
    %{
      title: @title,
      body: notification.body,
      tag: notification.id,
      notificationId: notification.id,
      url: "/dashboard",
      createdAt: notification.created_at
    }
  end

  defp attempt(subscription, payload) do
    case sender().push(subscription, payload) do
      :ok -> :ok
      {:error, _} = error -> error
      other -> {:error, {:invalid_sender_result, other}}
    end
  rescue
    exception -> {:error, {:exception, exception}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # Delete exactly the row that was attempted. The endpoint may have been
  # refreshed or reassigned to another principal while the push was in flight;
  # that newer row answers for itself on its own next delivery.
  defp remove_gone(%PushSubscription{id: id, principal_id: principal_id, auth: auth}) do
    PushSubscription
    |> where([s], s.id == ^id and s.principal_id == ^principal_id and s.auth == ^auth)
    |> Repo.delete_all()

    :ok
  end

  defp sender do
    Application.get_env(:dhc, :web_push_sender, HttpSender) || HttpSender
  end

  defp log_enqueue_failure(notification_id, principal_id, reason) do
    Logger.error(
      "[web-push] Could not enqueue delivery for notification #{notification_id} principal #{principal_id}: #{inspect(reason)}"
    )

    :ok
  end

  ## Changeset

  defp subscription_changeset(principal_id, attrs) do
    %PushSubscription{}
    |> Ecto.Changeset.cast(attrs, [:endpoint, :p256dh, :auth, :user_agent])
    |> Ecto.Changeset.validate_required([:endpoint, :p256dh, :auth])
    |> Ecto.Changeset.validate_length(:endpoint, max: 2048)
    |> Ecto.Changeset.validate_length(:user_agent, max: 512)
    |> validate_https_endpoint()
    |> validate_key(:p256dh, @p256dh_bytes)
    |> validate_key(:auth, @auth_bytes)
    |> put_principal(principal_id)
    |> Ecto.Changeset.put_change(:updated_at, DateTime.utc_now())
    |> Ecto.Changeset.foreign_key_constraint(:principal_id)
  end

  # The server will POST to this URL on the member's behalf, so it must look
  # like a push service: https, a real DNS name (never an IP literal or a
  # local/internal name), no credentials. A single trailing root dot is
  # stripped before those checks so `localhost.` / `127.0.0.1.` / `db.internal.`
  # cannot evade the exact-name, IP-literal, or suffix match; a leftover
  # trailing dot or empty host after the strip is rejected as malformed. A
  # public hostname with one trailing dot is accepted after that normalisation
  # (the stored URL keeps the dotted form). Redirects are refused at send time
  # (`HttpSender`), so a public host cannot bounce the request inward either.
  defp validate_https_endpoint(changeset) do
    Ecto.Changeset.validate_change(changeset, :endpoint, fn :endpoint, endpoint ->
      endpoint_errors(URI.new(endpoint))
    end)
  end

  defp endpoint_errors({:ok, %URI{scheme: "https", host: host, userinfo: nil}})
       when is_binary(host) and host != "" do
    case normalize_endpoint_host(host) do
      {:ok, hostname} ->
        if public_hostname?(hostname), do: [], else: [endpoint: "must be a public push service"]

      :error ->
        [endpoint: "must be an https URL"]
    end
  end

  defp endpoint_errors(_uri), do: [endpoint: "must be an https URL"]

  @local_suffixes [".local", ".localhost", ".internal", ".lan", ".home", ".arpa"]

  # One trailing root label only. `"."` becomes empty and `host..` still ends
  # in `.`; both are malformed. The caller must run every subsequent check on
  # this stripped host — in particular IP-literal detection.
  defp normalize_endpoint_host(host) do
    lowered =
      host
      |> String.downcase()
      |> String.replace_suffix(".", "")

    cond do
      lowered == "" -> :error
      String.ends_with?(lowered, ".") -> :error
      true -> {:ok, lowered}
    end
  end

  defp public_hostname?(host) do
    not (ip_literal?(host) or host == "localhost" or
           not String.contains?(host, ".") or
           Enum.any?(@local_suffixes, &String.ends_with?(host, &1)))
  end

  defp ip_literal?(host) do
    host = String.trim(host, "[]")

    match?({:ok, _}, :inet.parse_address(String.to_charlist(host)))
  end

  defp validate_key(changeset, field, expected_bytes) do
    Ecto.Changeset.validate_change(changeset, field, fn ^field, value ->
      case Base.url_decode64(value, padding: false) do
        {:ok, decoded} when byte_size(decoded) == expected_bytes -> []
        _ -> [{field, "must be a base64url value of #{expected_bytes} bytes"}]
      end
    end)
  end

  defp put_principal(changeset, principal_id) do
    case Ecto.UUID.cast(principal_id) do
      {:ok, principal_id} -> Ecto.Changeset.put_change(changeset, :principal_id, principal_id)
      :error -> Ecto.Changeset.add_error(changeset, :principal_id, "is invalid")
    end
  end
end
