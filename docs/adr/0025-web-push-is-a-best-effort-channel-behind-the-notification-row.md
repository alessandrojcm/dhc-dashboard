# Web Push Is a Best-Effort Channel Behind the Notification Row

**Status:** Accepted  
**Date:** 2026-09-16  
**Tags:** notifications, web-push, oban, pwa, service-worker

## Context

Notifications are durable rows (`notifications`) created through `Dhc.Notifications.create/2` and `create_keyed/3`, with a best-effort Phoenix PubSub broadcast after commit so an open dashboard refetches. Members asked to be told about loan approvals and reminders while the PWA is closed (ALE-299 / GH-506). Web Push (RFC 8030/8291/8292) can do that, but it introduces a second delivery path with its own failure modes: a browser's subscription dies (404/410), a push service throttles (429), a payload is refused (413), a member has several devices, iOS only offers the Push API to an installed web app, and a permission denial is permanent until the member changes it.

The risk was letting any of that leak back into notification creation — a rolled-back row because a push failed, a duplicate row or duplicate push from a retry, or a stored endpoint/key becoming visible to a client.

## Decision

1. **The row is the source of truth; push is a channel after commit.** `Dhc.Notifications` gains one private `signal_created/1` that runs the existing PubSub broadcast *and* `Dhc.Notifications.WebPush.enqueue_delivery/1`. Both are best-effort by contract: each logs and returns, so the only outcome a creator can observe is the committed row. `create_keyed/3` signals only on `:created`, so a suppressed duplicate neither re-broadcasts nor re-pushes.

2. **One Oban job per notification, one attempt per browser, no job-level retry.** `Dhc.Notifications.Workers.WebPushWorker` (`queue: :notifications`, `max_attempts: 1`, unique on `notification_id`) loads the row and calls `WebPush.deliver/1`, which attempts every subscription of the recipient once and returns `%{sent, removed, failed}`. A `{:error, :gone}` (404/410) deletes that subscription; anything else is counted and logged with the subscription id. A job-level retry would re-push to browsers that already succeeded, which is the duplicate the ticket forbids; a missing row cancels the job.

3. **Subscriptions are per browser installation, identified by endpoint.** `notification_push_subscriptions.endpoint` is globally unique; `WebPush.subscribe/2` upserts on it, refreshing keys for the same browser and *reassigning* an endpoint last registered under another principal (a shared device can only be delivering for whoever is signed in). `unsubscribe/2` is scoped to the caller and idempotent. Rows cascade with the principal.

4. **Disclosure is minimal by construction.** The API (`notificationsPush.config|subscribe|unsubscribe`) returns the VAPID public key, `{id, createdAt}`, and `{removed}`. Endpoint URLs, `p256dh`/`auth`, and the private key never appear in a response, a log line, or the generated client types (the parity test asserts the last).

5. **The HTTP hop is a seam.** `Dhc.Notifications.WebPush.Sender` is a behaviour resolved via `:web_push_sender` (like `:notification_broadcaster`); the default `HttpSender` builds the request with `web_push_ex` (aes128gcm + VAPID, no I/O) and sends it with Req, so Req stays the only HTTP client and tests route the POST through a Req `plug:`.

6. **The endpoint is member-supplied, so the server treats it as untrusted egress.** `subscribe/2` accepts only `https` URLs with a public DNS hostname (no IP literals, `localhost`, single-label or `.local`/`.internal`-style names, no credentials) and `HttpSender` never follows redirects. What remains is a blind POST of an opaque encrypted body whose only observable outcome is a 404/410 deleting the caller's own row; DNS-rebinding to a private address is the accepted residual.

7. **The browser decides its own state without prompting.** `apps/web/src/lib/notifications/web-push/` is pure: `decidePushAvailability` orders the explanations (server-disabled → iOS install required → unsupported → denied → available) and the workflow reads on/off from `PushManager.getSubscription`, re-registering an existing subscription on load (idempotent upsert) and only ever calling `subscribe` — the one call that can prompt — from the member's click. The service worker's `push`/`notificationclick` decisions live in `$lib/service-worker/push.ts` and only honour same-origin paths.

## Consequences

- VAPID configuration is optional everywhere: without `WEB_PUSH_VAPID_*` the config endpoint reports `enabled: false`, the toggle explains that push is unavailable, and no job is enqueued. Tests use a fixed throwaway pair in `config/test.exs`.
- A push service outage loses one best-effort push per notification and nothing else; the notification centre still shows the row.
- A stale server row (member disabled push but the unregister call failed) is removed by the push service's next 404/410.
- Rotating the VAPID pair invalidates every browser subscription at the push service. The workflow compares the browser's `applicationServerKey` with the configured key on load, drops a mismatched subscription and shows "off", so a member sees they must opt in again instead of a permanent silent "on".
- An existing browser subscription that the server refuses to confirm is shown as an error, never as "on", and keeps a "Turn off on this device" action so the member is not trapped.
- Sign-out drops the browser's subscription (server row first, while the cookie can still authorise it), so a shared device stops receiving the departing member's notifications. Delivery still reads the subscription rows before the network hop; a reassignment landing inside that window is an accepted residual (the `gone` cleanup deletes only the exact row snapshot it attempted).
- Push clicks land on `/dashboard`; the root route is an empty page.
- Fixing this path exposed that the `notifications:self` channel alias never subscribed to the principal's canonical PubSub topic, so open dashboards never received `notification_created`; the alias now subscribes and relays, with a regression test.

## Considered options

- **Enqueue the push job inside the notification transaction** (guaranteed delivery attempt). Rejected: it couples the row to Oban availability and contradicts "delivery failures must not affect creation".
- **Retry the job on transient failure.** Rejected without per-subscription bookkeeping: it duplicates pushes to healthy browsers. Could be revisited by re-enqueueing only failed subscription ids.
- **`web_push_elixir` / `web_push_encryption`.** Rejected: both still emit the obsolete `aesgcm` encoding and own their HTTP client.
- **One subscription per principal.** Rejected: members use a phone PWA and a laptop, and each device must be revocable on its own.
