# Phoenix notification realtime migration specification

## Outcome

Replace the notification listener in `NotificationCenter` with an authenticated,
per-user Phoenix Channel. The channel carries only a best-effort signal that a
Notification was created; notification data, read state, pagination, and unread
counts remain owned by the Phoenix HTTP API.

This is a coordinated big-bang release. Do not dual-run both realtime systems or
add a feature flag.

## Event contract

- Topic: `notifications:<supabase-user-id>`
- Event: `notification_created`
- Payload: `%{}` on the server and `{}` in the browser
- Meaning: a Notification for the authenticated topic owner was durably committed
- Client response: invalidate the existing notifications infinite-query key and
  refetch authoritative state through the API

The event is deliberately not a data-transfer contract. Do not include a
Notification representation or mutate the query cache from its payload.

## Server implementation

### Socket and channel

1. Mount `DhcWeb.UserSocket` at `/socket` in `DhcWeb.Endpoint` with WebSocket
   transport enabled, long polling disabled, and Phoenix 1.8 `auth_token` enabled.
2. In `DhcWeb.UserSocket.connect/3`, require a non-empty
   `connect_info[:auth_token]`, verify it through the configured
   `Dhc.Auth.SupabaseJwt` verifier boundary, and assign the verified `sub`.
   Missing, invalid, expired, and verifier-error tokens must reject the socket.
3. Return `"users_socket:#{sub}"` from `id/1`.
4. Route `notifications:*` to a notification channel. Its `join/3` must compare
   the topic suffix exactly with the verified `sub`; return `{:ok, socket}` only
   for the user's own topic and `{:error, %{reason: "unauthorized"}}` otherwise.
5. Broadcast `notification_created` with `%{}` only to the committed
   Notification owner's topic.

### Commit-safe creation

Make `Dhc.Notifications.create/2` the only supported Notification creation API.

1. Reject entry when `Dhc.Repo.in_transaction?/0` is true with the explicit
   nested-transaction error selected by the implementation.
2. Build and insert the Notification through an `Ecto.Multi` passed to a
   transaction owned by this function.
3. Make exactly one application broadcast attempt only after
   `Repo.transact/2` returns `{:ok, %{notification: notification}}`.
4. Preserve the existing caller contract, `:ok | {:error, term()}`.
5. Keep raw insertion private to the Notifications context. Update the bulk
   invitation path to call the context API rather than
   `Dhc.Notifications.Repository.create/2`; remove the public repository create
   path when it is no longer needed.
6. If insertion fails or rolls back, do not broadcast.
7. If broadcasting fails, log an error with notification and user identifiers,
   but return database success and retain the committed row. Do not return an
   error that could prompt the caller to duplicate the Notification.

The guarantee is one broadcast attempt after successful outermost commit, not
exactly-once delivery. Do not add Oban, an outbox, replay storage, an idempotency
contract, or observation of direct SQL writes.

### Read state

Do not broadcast `mark_read` or `mark_all_read` changes. Local mutations already
invalidate the HTTP query. Read-state changes made in another tab or device
converge on the next ordinary refetch rather than through realtime delivery.

## Browser implementation

1. Add the official `phoenix` package as a runtime dependency on the Phoenix 1.8
   line used by the server.
2. In the browser-only lifecycle of
   `src/lib/components/notifications/NotificationCenter.svelte`, remove the
   Supabase `postgres_changes` subscription completely.
3. Obtain the current Supabase session. When it has an access token and user ID,
   construct `Socket(PUBLIC_PHOENIX_SOCKET_URL, { authToken: accessToken })`,
   connect it, and join `notifications:<session.user.id>`.
4. Invalidate the exact existing `notificationsListInfiniteQueryKey(...)` when
   `notification_created` arrives and whenever an initial join or rejoin
   succeeds. Rejoin invalidation repairs events missed while disconnected.
5. On Supabase `TOKEN_REFRESHED`, leave and disconnect the old channel/socket,
   then construct a new instance with the new access token. Do not mutate the
   client's undocumented token field.
6. On `SIGNED_OUT` and component cleanup, remove listeners, leave the channel,
   and disconnect the socket.
7. Authentication, connection, join, and reconnect failures must not block query
   rendering or HTTP mutations. Do not show a realtime-specific error to the
   user. Log diagnostic warnings and allow Phoenix's normal reconnect/rejoin
   behavior to recover.

Duplicate events and invalidations are harmless. Events missed while offline are
not replayed; successful rejoin plus HTTP refetch is the recovery mechanism.

## Configuration and deployment

Add the public frontend setting beside the existing API configuration:

```dotenv
# Local
PUBLIC_PHOENIX_SOCKET_URL=ws://localhost:4000/socket

# Production
PUBLIC_PHOENIX_SOCKET_URL=wss://dhc-dashboard.fly.dev/socket
```

Configure the socket's effective production `check_origin` allow-list from the
existing `CORS_ALLOWED_ORIGINS`. It must accept
`https://dashboard.dublinhemaclub.com` and reject unrelated origins. Do not use
`check_origin: false` or a wildcard in production. The current development-only
origin relaxation may remain.

The existing Fly `[http_service]` is sufficient for WebSocket upgrades: it
forwards public HTTP/TLS traffic to Bandit on internal port 8080. Do not add a
Fly service, port, handler, TCP health check, proxy-header rule, or WebSocket
concurrency setting for this migration. Keep the current HTTP health check and
always-running Machine configuration.

No new Phoenix token, JWT package, browser secret, or service-role exposure is
required.

## Big-bang cutover and rollback

1. Land and release the server socket/channel, commit-safe broadcaster, browser
   replacement, dependency, and environment configuration as one coordinated
   change.
2. Do not deploy a dual-running stage and do not add a feature flag.
3. Keep the `notifications` table in the Supabase Realtime publication; removing
   it is outside this migration.
4. Immediately verify production socket authentication, own-topic join, event
   delivery, and resulting API refetch.
5. If verification fails, roll the Cloudflare frontend back to its previous
   build, which restores the Supabase listener. The additive Phoenix socket code
   may remain deployed while the failure is diagnosed.

## Required focused tests

### Notifications context

- A successful create commits one row and makes one broadcast attempt after the
  transaction returns.
- A failed insert or rollback creates no row and emits no signal.
- Calling `Dhc.Notifications.create/2` inside an outer transaction is rejected
  and emits no signal.
- A broadcast error leaves the row committed, reports success to the caller, and
  is logged.
- Two successful calls create two rows and make two attempts.
- The bulk-invite path creates its existing admin Notification and emits one
  signal.

### Socket and channel

- Valid verified claims authenticate the socket and assign the user ID.
- Missing, invalid, expired, and verifier-error tokens reject it.
- A user can join only `notifications:<their-sub>`.
- A broadcast reaches the intended user's channel and not another user's
  channel.
- The configured production browser origin is accepted and an unrelated origin
  is rejected.

### NotificationCenter

- The current token is supplied as `authToken` and the current user's topic is
  joined.
- `notification_created` invalidates the existing infinite-query key.
- Successful initial join and rejoin invalidate that same key.
- `TOKEN_REFRESHED` replaces the connection with one using the new token.
- `SIGNED_OUT` and component cleanup leave and disconnect.
- Connection and join errors leave HTTP query rendering and mutations usable.

Full browser E2E coverage is not required.

## Supporting decisions

- [Commit-safe notification creation broadcasts](commit-safe-notification-broadcasts.md)
- [Secure Phoenix Channel browser integration](secure-phoenix-channel-browser-integration.md)
- [Fly configuration reference](https://fly.io/docs/reference/configuration/)
- [Fly public network services](https://fly.io/docs/networking/services/)
