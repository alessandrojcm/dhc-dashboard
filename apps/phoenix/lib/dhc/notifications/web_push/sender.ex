defmodule Dhc.Notifications.WebPush.Sender do
  @moduledoc """
  ALE-299: the one hop that leaves the process — encrypt a payload for a
  browser and POST it to that browser's push service.

  Resolved at runtime through `Application.get_env(:dhc, :web_push_sender)`
  (mirroring `:notification_broadcaster`) so tests substitute a recording
  sender instead of reaching the network. The default is
  `Dhc.Notifications.WebPush.HttpSender`.

  Implementations MUST classify the push service's answer so the context can
  act on it without knowing HTTP:

    * `:ok` — accepted (RFC 8030 uses 201; services also answer 200/202).
    * `{:error, :gone}` — 404 or 410: the subscription no longer exists at the
      push service and must be deleted. Retrying it can never succeed.
    * `{:error, reason}` — anything else (413, 429, 5xx, transport error).
      The subscription is kept; the attempt is simply lost.

  A raise is treated as `{:error, reason}` by the caller, but implementations
  should still prefer returning errors.
  """

  alias Dhc.Notifications.PushSubscription

  @type payload :: %{required(atom()) => term()}
  @type result :: :ok | {:error, :gone} | {:error, term()}

  @callback push(PushSubscription.t(), payload()) :: result()
end
