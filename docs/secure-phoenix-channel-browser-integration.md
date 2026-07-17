# Secure Phoenix Channel browser integration

## Decision

Use Phoenix 1.8.7's native socket `auth_token` transport option with the official `phoenix` JavaScript client. Pass the current Supabase access token through `Socket`'s `authToken` option, verify it with the existing `Dhc.Auth.SupabaseJwt` boundary in the socket's `connect/3`, and assign the verified Supabase `sub` to the socket. Authorize a per-user notification topic in `join/3` by comparing its user ID with that assigned `sub`.

Keep this best-effort integration local to `NotificationCenter`. Rebuild it when Supabase issues a new access token, tear it down on component cleanup or sign-out, and invalidate the existing notifications query both when a notification signal arrives and after every successful channel join or rejoin. The join invalidation recovers authoritative HTTP state after events missed while disconnected.

## Required server shape

### Endpoint

Mount one WebSocket-only socket at `/socket`:

```elixir
socket "/socket", DhcWeb.UserSocket,
  websocket: true,
  longpoll: false,
  auth_token: true
```

Phoenix 1.8.7 documents `auth_token: true` as the supported way to expose the JavaScript client's `authToken`: WebSocket carries it in `Sec-WebSocket-Protocol`, and Phoenix exposes it as `connect_info[:auth_token]`. This avoids putting a bearer token in the URL query string. Do not replace it with `params: %{token: ...}` or a cookie-backed session.

The application does not need long polling for a best-effort invalidation signal. Keeping `longpoll: false` also avoids introducing CORS handling and a second transport lifecycle for this migration.

### Socket authentication

`DhcWeb.UserSocket.connect/3` must accept only a non-empty `auth_token`, call `Dhc.Auth.SupabaseJwt.verify/1`, and assign the returned claims (or at least `claims.sub`) to the socket. Reject missing, invalid, and expired tokens with `:error` or `{:error, reason}`. Reuse the configured `:auth_verifier` seam so socket tests can use the same verifier substitution as HTTP auth tests.

Use a user-scoped socket ID such as `"users_socket:#{sub}"`; Phoenix supports broadcasting `"disconnect"` to this ID if the application later needs server-initiated revocation. This identifier is not a substitute for join authorization.

The existing verifier already uses `Supabase.Auth.get_claims/3`, verifies against Supabase, and returns the JWT `sub`. No Phoenix token minting or new JWT library is required.

### Per-user channel authorization

Expose a channel pattern such as `"notifications:*"`. The browser joins `"notifications:#{session.user.id}"`; `join/3` must return `{:ok, socket}` only when the topic suffix exactly equals the verified `socket.assigns.current_user.sub`, and otherwise return `{:error, %{reason: "unauthorized"}}`.

Broadcast the commit-safe signal to that same topic. Keep the event small (for example, `"notification_created"` with `%{}` or only an opaque notification ID): the event grants no data access and only triggers an authenticated API refetch. Phoenix requires channel authorization in `join/3`; merely authenticating the socket is insufficient.

## Required browser shape

Add the official `phoenix` npm package as a runtime dependency at the same 1.8 line as the server. In `NotificationCenter`'s browser-only mount lifecycle:

1. obtain the current Supabase session and access token;
2. construct `new Socket(PUBLIC_PHOENIX_SOCKET_URL, { authToken: accessToken })`;
3. call `socket.connect()`;
4. join `notifications:${session.user.id}`;
5. invalidate `notificationsListInfiniteQueryKey(...)` on `notification_created`;
6. also invalidate after each successful join/rejoin; and
7. on cleanup, leave the channel, remove auth listeners, and disconnect the socket.

Use the documented `channel.on`, `channel.join().receive(...)`, `channel.leave()`, and `socket.disconnect()` APIs. Phoenix JS automatically reconnects a dropped socket and rejoins errored channels with backoff. Socket and channel error hooks may report observability state, but socket failure must not disable HTTP query and mutation behavior.

`authToken` is a string captured by the Phoenix 1.8.7 client, not a token callback. Supabase access tokens are short-lived and refreshed continuously. Listen for Supabase auth changes: on `TOKEN_REFRESHED`, cleanly replace the socket/channel with a new instance carrying the new access token; on `SIGNED_OUT`, tear it down without reconnecting. Do not mutate the undocumented `socket.authToken` field. A connection accepted before token expiry is not automatically reauthenticated by Phoenix, so planned replacement is the authentication boundary for refreshed sessions.

The current component already receives the Supabase browser client and owns the exact notifications query key, so no shared realtime service is needed.

## Origin and deployment configuration

WebSocket origin validation and HTTP CORS are separate controls. `DhcWeb.Plugs.Cors` does not authorize the socket handshake. Phoenix defaults `check_origin` to the configured Endpoint host; that would reject the production cross-origin connection because the browser origin is `https://dashboard.dublinhemaclub.com` while `PHX_HOST` is `dhc-dashboard.fly.dev`.

Require the socket transport's effective `check_origin` allow-list to be derived from the existing runtime `CORS_ALLOWED_ORIGINS` setting. Production is already configured with exactly `https://dashboard.dublinhemaclub.com`; do not use `check_origin: false` in production and do not allow a wildcard. The existing development-only `check_origin: false` may remain local-only, although using the existing localhost origin list is stricter.

Fly's existing `[http_service]` exposes HTTP/TLS on ports 80/443, terminates TLS, forces HTTPS, and forwards the upgraded request to Bandit on port 8080. No new Fly service or port is required. Production browser connections must use `wss://`.

Add one public frontend variable:

```dotenv
# Local
PUBLIC_PHOENIX_SOCKET_URL=ws://localhost:4000/socket

# Production
PUBLIC_PHOENIX_SOCKET_URL=wss://dhc-dashboard.fly.dev/socket
```

Keep `PUBLIC_API_BASE_URL` unchanged for HTTP. A separate socket URL avoids incorrectly appending `/socket` to the current `/api` base and makes the cross-origin deployment explicit. The value is public routing configuration, not a secret. Continue to configure server-side Supabase verification with `SUPABASE_URL` and `SUPABASE_ANON_KEY`/`SUPABASE_SERVICE_ROLE_KEY`; never expose a service-role key to the browser.

## Reconnect and failure semantics

Phoenix JS automatically reconnects unclean socket closures and rejoins errored channels. Events emitted while disconnected are not replayed. Invalidation after every successful join/rejoin is therefore required: it repairs the query from the authoritative API without introducing sequence IDs, replay storage, an outbox, or direct cache mutation.

An initial authentication or join failure leaves notifications usable over HTTP. A later query refetch, mutation invalidation, remount, or successful reconnect remains the recovery path. Duplicate signals and duplicate invalidations are harmless.

## Verification seams

Server tests should cover:

1. valid Supabase claims authenticate the socket and assign the verified user ID;
2. missing, invalid, and verifier-error tokens reject the socket;
3. a user can join only their own `notifications:<sub>` topic;
4. a broadcast to one user's topic reaches that user's channel and not another user's channel; and
5. the configured production origin is accepted while an unrelated origin is rejected.

Focused component/client tests should inject or mock the Phoenix client boundary and cover:

1. the current Supabase token is supplied as `authToken` and the current user's topic is joined;
2. `notification_created` invalidates the exact existing infinite-query key;
3. successful initial join and rejoin invalidate the same key;
4. `TOKEN_REFRESHED` replaces the connection with the new token;
5. cleanup and `SIGNED_OUT` leave/disconnect without breaking HTTP behavior; and
6. connection/join errors do not block query rendering or notification mutations.

Full browser E2E remains outside this map.

## Sources

- Phoenix 1.8.7 `Endpoint.socket/3`: transport options, `auth_token`, `check_origin`, and `connect_info` — <https://hexdocs.pm/phoenix/1.8.7/Phoenix.Endpoint.html#socket/3>
- Phoenix 1.8.7 `Phoenix.Socket`: authentication in `connect/3`, socket assigns/IDs, and channel routing — <https://hexdocs.pm/phoenix/1.8.7/Phoenix.Socket.html>
- Phoenix 1.8.7 `Phoenix.Channel`: mandatory authorization in `join/3` and topic broadcasts — <https://hexdocs.pm/phoenix/1.8.7/Phoenix.Channel.html>
- Phoenix 1.8.7 JavaScript client API: `authToken`, lifecycle hooks, reconnect, and rejoin behavior — <https://hexdocs.pm/phoenix/1.8.7/js/index.html>
- Phoenix 1.8.7 JavaScript client source: `authToken` is stored as a string and sent through WebSocket subprotocols on each transport connection — <https://github.com/phoenixframework/phoenix/blob/v1.8.7/assets/js/phoenix/socket.js>
- Supabase sessions: short-lived access tokens and continuous refresh — <https://supabase.com/docs/guides/auth/sessions>
- Supabase JWTs: claims, expiry, and supported verification — <https://supabase.com/docs/guides/auth/jwts>
- Fly public network services: `[http_service]`, TLS termination, and HTTPS routing — <https://fly.io/docs/networking/services/>

## Repository evidence

- `apps/phoenix/mix.exs` pins Phoenix `~> 1.8.7`.
- `apps/phoenix/lib/dhc/auth/supabase_jwt.ex` is the existing Supabase verification boundary.
- `apps/phoenix/lib/dhc_web/endpoint.ex` currently has no application socket.
- `apps/phoenix/config/runtime.exs` and `fly.toml` already define the production host and browser-origin allow-list.
- `src/routes/+layout.svelte` already obtains fresh access tokens for the HTTP client and listens to Supabase auth changes.
- `src/lib/components/notifications/NotificationCenter.svelte` currently owns the Supabase Realtime subscription and exact TanStack Query invalidation key.
- `.env.example` already documents `PUBLIC_API_BASE_URL` and `CORS_ALLOWED_ORIGINS`; the socket URL belongs beside them.
