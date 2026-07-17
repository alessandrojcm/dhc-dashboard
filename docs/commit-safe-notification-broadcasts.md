# Commit-safe notification creation broadcasts

## Decision

Use one transaction-owning application API, `Dhc.Notifications.create/2`, as the only supported way to create a notification. It must:

1. reject calls when `Dhc.Repo.in_transaction?/0` is already true;
2. insert the notification in a transaction it owns;
3. wait for `Repo.transact/2` to return successfully; and
4. make one best-effort PubSub broadcast attempt after that return.

Keep the raw insert private to the notifications context. Do not add an Oban worker or outbox for this best-effort invalidation signal.

The guarantee is **one application broadcast attempt after a successful outermost transaction return**, not exactly-once delivery. A process crash between commit and broadcast can lose the signal; PubSub or channel delivery can also fail. Those gaps are acceptable because clients continue to read authoritative state over HTTP.

## Current creation paths

There is one Ecto insertion path:

- `apps/phoenix/lib/dhc/notifications/repository.ex:13` builds the notification and calls `Repo.insert/1` at line 20.
- `apps/phoenix/lib/dhc/invitations/repository.ex:157` calls that API from `create_processing_notification/2`.
- `apps/phoenix/lib/dhc/invitations/workers/bulk_invite_worker.ex:121` stores the processing log and then creates the notification. This happens after all per-invite transactions in `create_invitation_pipeline/4` have returned; the notification insert is not inside those transactions.

No other Phoenix/Ecto notification insert or upsert path exists. Direct SQL writes deliberately remain invisible.

## Transaction boundary

Ecto 3.14's [`Repo.transact/2`](https://hexdocs.pm/ecto/3.14.0/Ecto.Repo.html#c:transact/2) commits a successful function or `Ecto.Multi` before returning `{:ok, value}`. An `Ecto.Multi` is a useful explicit boundary here: insert the row as `:notification`, then broadcast only while handling `{:ok, %{notification: notification}}` outside `Repo.transact/2`.

Conceptually:

```elixir
def create(user_id, body) do
  if Repo.in_transaction?() do
    {:error, :notification_create_inside_transaction}
  else
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:notification, notification_changeset(user_id, body))
    |> Repo.transact()
    |> after_commit_signal()
  end
end

defp after_commit_signal({:ok, %{notification: notification}}) do
  notification
  |> Broadcaster.notification_created()
  |> log_broadcast_error(notification)

  :ok
end

defp after_commit_signal({:error, _operation, reason, _changes}), do: {:error, reason}
```

The exact return shape should preserve the current caller contract (`:ok | {:error, term()}`). A PubSub error is logged with the notification and user identifiers, but does not turn a committed database write into an application error that callers might retry.

### Why the guard is required

Ecto exposes [`Repo.in_transaction?/0`](https://hexdocs.pm/ecto/3.14.0/Ecto.Repo.html#c:in_transaction?/0) specifically to detect whether the current process is already in a transaction. Without the guard, a caller could invoke this API inside a larger transaction: the inner `Repo.transact/2` could return before the outer transaction commits, causing the subsequent broadcast to expose data that may still roll back.

Failing fast is safer than silently skipping the signal. If a future workflow must create a notification atomically with other writes, that workflow's outermost context must own the complete `Ecto.Multi`, return the inserted notification from it, and broadcast after its own `Repo.transact/2` returns. That is a new explicit API/design case, not permission to call `create/2` from a transaction.

## Delivery semantics

[`Phoenix.PubSub.broadcast/4`](https://hexdocs.pm/phoenix_pubsub/2.2.0/Phoenix.PubSub.html#broadcast/4) returns `:ok | {:error, term()}` for the broadcast operation. PubSub is transient: it does not persist events or replay them to disconnected clients. It also permits duplicate subscriptions for the same PID/topic, which produce duplicate deliveries ([`subscribe/3`](https://hexdocs.pm/phoenix_pubsub/2.2.0/Phoenix.PubSub.html#subscribe/3)). Therefore neither PubSub nor Channels can provide exactly-once client delivery.

The application can still guarantee one call to the broadcaster for each successful invocation of `Dhc.Notifications.create/2`. Two successful API calls intentionally create two rows and make two attempts; there is no domain idempotency key today. A caller retry after an uncertain response can therefore duplicate both the row and signal, as it already can duplicate the row now.

## Why not Oban/outbox

Oban can enqueue a job atomically with database changes, including through its [`Ecto.Multi` integration](https://hexdocs.pm/oban/2.23.0/Oban.html#insert/5). That solves the crash gap between commit and scheduling. It does not provide exactly-once broadcasting: Oban retries failed or crashed jobs, so a worker that broadcasts and then crashes before completion may broadcast again. Unique jobs constrain enqueueing, not side-effect execution ([Oban unique jobs](https://hexdocs.pm/oban/2.23.0/unique_jobs.html)).

Durable retry, worker lifecycle, deduplication, and extra latency are contrary to this map's intentionally best-effort cache-invalidation signal. HTTP refetch remains the recovery mechanism.

## Verification seams

Add focused notifications-context tests with a subscriber or injectable broadcaster boundary:

1. **Commit succeeds:** one row exists and exactly one broadcaster call/message occurs with that row's user ID.
2. **Insert rolls back:** force the `Ecto.Multi` insert to fail; assert no row and no broadcaster call/message.
3. **Nested use is rejected:** call `Dhc.Notifications.create/2` inside `Repo.transact/2`; assert the explicit transaction error and no row/message.
4. **Broadcast returns an error:** assert the API still reports database success, the row remains, and the failure is observable through the chosen log/telemetry seam.
5. **Repeated calls:** two successful calls create two rows and two attempts; no accidental deduplication is claimed.

Extend the existing bulk invite worker test at `apps/phoenix/test/dhc/invitations/workers/bulk_invite_worker_test.exs:134` to subscribe to the admin's topic and assert one signal alongside the existing notification-row assertion. Channel authorization and forwarding belong to the separate channel-integration tests.
