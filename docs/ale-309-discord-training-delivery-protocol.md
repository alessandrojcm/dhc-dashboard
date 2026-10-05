# Discord Training Occurrence delivery protocol

**Status:** Decided (wayfinder grilling, 2026-09-21)  
**Ticket:** ALE-309 — part of the map *Specify dashboard-owned Discord Training notifications* (ALE-305)  
**Depends on:** ALE-306 (Discord delivery and thread constraints), ALE-308 (Training recurrence and exception semantics)  
**Scope:** Delivery identity, state progression, failure policy, rendering, routing, and scheduling of one Discord notification per Training Occurrence. Module placement, API shape, holiday announcements, retention and cutover belong to later tickets.  
**Naming (ALE-311):** read *Training* as **Training Announcement**, *Training Occurrence* as **Announcement Occurrence**, and *Discord Training Delivery* as **Discord Announcement Delivery** — see the rename table in `docs/ale-311-training-announcements-boundary.md`.

## Scale assumption

One club, a handful of committee members, one or two Trainings per kind. Two people editing the same Training at once is not a realistic scenario, so the protocol relies on database uniqueness and Oban's own job uniqueness for correctness rather than on row-locking ceremony. Nothing below requires more than one Phoenix node.

## Delivery identity

Every Training Occurrence has at most one **Discord Training Delivery**, uniquely identified by `(training_id, occurrence_date)` where `occurrence_date` is the Europe/Dublin local date. The delivery row, not an Oban job, is the identity that guarantees at-most-one visible notification. Jobs carry only the delivery/occurrence reference and are disposable drivers.

The unique index on `(training_id, occurrence_date)` is the only fence against duplicates from double jobs, late jobs, or manual re-runs; a second insert simply fails and the loser exits.

## Scheduling: one self-perpetuating job per Training

There is no per-minute discovery cron. Each Training owns **at most one pending Oban job** (Oban `unique` keyed on `training_id`), scheduled at the next occurrence's send time.

The **send time is the Training's scheduled time**. The Training calendar is a schedule of posts: a "sparring" Training at Wednesday 10:00 means the sparring roll call is posted Wednesday 10:00, exactly as the current bot's sparring calendar works. There is no separate lead-time field.

When the job runs it:

1. resolves the occurrence under the ALE-308 precedence *at that moment* — bank holiday → Training Disablement → Training Suppression → Training Override → Training defaults;
2. either delivers (below), records `skipped` with the reason (holiday / disabled / suppressed), or records `missed` when the send window has passed;
3. enqueues itself for the next occurrence. A one-off gets exactly one job and stops.

**Which edits touch jobs.** Changing weekday/time, disabling, re-enabling, deleting or retiring a Training cancels its pending job and enqueues a fresh one (or none). Suppressions, Overrides and bank holidays never touch jobs — they are read when the job runs, so exception edits stay write-free on the delivery path.

**Late window.** After downtime Oban runs the late job. It delivers if the current Europe/Dublin date still equals the occurrence date; otherwise it records `missed` and moves on. A roll call at 14:00 instead of 10:00 is useful; one on the following day is noise.

## Validation before freeze

Nothing is frozen until the payload is provably deliverable. Before the delivery row is created the worker validates:

- the Training resolves to a non-empty title and message after overrides;
- every template token is known (see Rendering) and the rendered message is ≤ 2,000 characters;
- the resolved title fits Discord's thread-name limit (100 characters) — never silently truncated;
- the kind's destination channel is configured for this deployment.

A validation failure does **not** create a delivery row: the occurrence is recorded as `blocked` with the reason, a Sentry event is raised, and the next occurrence tries again naturally. This lets committee members fix bad copy without manufacturing delivery history.

## Freeze

Once valid, one transaction inserts the delivery in state `frozen` with the snapshot ALE-308 requires:

- occurrence date, local start/end time;
- effective title and message *source* after overrides;
- rendered message and thread name;
- `@everyone` setting and notification kind;
- resolved destination channel id.

From this point the delivery is the point of no return: a later disablement or suppression does not cancel it (the window is minutes wide and cancelling would reopen the ambiguity problem for no product gain). Edits committed after the freeze affect only later occurrences.

## Progression

States are monotonic checkpoints; provider ids are written as soon as they are known and are never erased.

```text
frozen
  → posting_message        (committed BEFORE the Discord call)
  → message_posted         (message id stored)
  → creating_thread
  → delivered              (thread id stored)

posting_message  → message_uncertain      terminal
creating_thread  → thread_failed          terminal (message stands)
any              → blocked                terminal (deterministic failure)
```

**Crash fence.** `posting_message` is committed *before* calling Discord. If the worker dies in that state the next run cannot know whether the message went out and moves the delivery to `message_uncertain`. This knowingly trades an occasional missed roll call for never posting a duplicate — Discord offers no complete idempotency primitive (ALE-306), so positive proof is required before repeating a message call. A stable Discord `nonce` is still sent as cheap extra protection, never as the guarantee.

**Message stands, thread is best-effort.** Once a message id exists the message *is* the notification. Thread creation is retried on definitive failures with Oban's normal backoff; on exhaustion or an ambiguous thread response the delivery ends as `thread_failed` with the message id retained. It never reposts the message and never creates a competing thread. This matches the current bot, which logs and ignores thread failures.

## Failure classification

| Outcome | Examples | Policy |
| --- | --- | --- |
| Safe retry | Nostrum rate-limit deferral before submission; connection refused before request | Retry in the same state; no state change |
| Blocked | 403 missing permission, 404 unknown channel, invalid snowflake, 400 payload rejection | Terminal `blocked`, Sentry event, no retry |
| Uncertain | timeout, connection loss after submission may have begun, 5xx, worker death while `posting_message`, success response without a trustworthy message id | Terminal `message_uncertain`, Sentry event, no retry |
| Terminal | invalid frozen payload (should be impossible after validation) | Terminal `blocked` |

Unknown errors default to **uncertain**, not retryable. Thread creation follows the same table except that its known failures may retry, since retrying cannot create a second channel message.

## No reconciliation UI

Uncertain, blocked and thread-failed deliveries are rare at this scale. They are retained as evidence and surfaced only through logs and Sentry; there is no operator reconciliation screen, no "confirm posted" attestation, and no retargeting of a frozen delivery to a corrected channel. If a channel is misconfigured the fix is deployment configuration and the next occurrence.

## Mention safety

Free text always renders **literally**. Whether anything pings is decided exclusively by `allowed_mentions`:

- `@everyone` toggle off → `allowed_mentions: { parse: [] }`;
- toggle on → `allowed_mentions: { parse: ["everyone"] }`, and the system prepends `@everyone` and a newline to the rendered message. Copy authors never type the mention.

User mentions, role mentions and replied-user pings are disabled in both cases. The bot needs `VIEW_CHANNEL`, `SEND_MESSAGES`, `CREATE_PUBLIC_THREADS`, plus `MENTION_EVERYONE` when the toggle is on (ALE-306).

## Rendering

Editable copy uses a small, non-programmable token vocabulary, validated before freeze:

| Token | Renders |
| --- | --- |
| `{{title}}` | resolved Training title |
| `{{date}}` | occurrence date, fixed Europe/Dublin format (e.g. `Thursday 25 September`) |
| `{{startTime}}` | scheduled start, `HH:MM` Europe/Dublin |
| `{{endTime}}` | scheduled end, `HH:MM` Europe/Dublin |

Unknown or malformed tokens fail validation. Preview uses the same renderer and shows the final result including the `@everyone` line. The delivery stores both source and rendered copy; Discord calls send only the rendered copy.

The resolved title doubles as the **thread name**, so one title means the same thing in the calendar, the delivery evidence and Discord. Threads use a fixed 24-hour auto-archive. The current bot's third call — a "this thread was automatically created" starter message inside the thread — is dropped.

## Routing

Routing is fixed and deployment-configured:

```text
roll_call → configured roll-call channel
sparring  → configured sparring channel
```

No stored arbitrary channel, no caller-supplied channel, no fallback channel, no cross-kind fallback. Missing configuration is a validation failure (`blocked`), so deployment readiness is testable without posting.

## Facts from the current bot relevant to later tickets

- It is a run-once process (`restart_policy = 'never'`); its daily start time lives outside the repository. It has no time-of-day logic — it posts for "today" whenever it runs.
- Dedup is per `(date, kind)` in an embedded Badger store with a one-month TTL; one message per day per kind regardless of event count.
- Current copy: roll call `Hey @everyone! It's {Weekday}! Who is coming to training tonight? ⚔️`, thread `Roll call {Month D}`; sparring `Hey @everyone! Who is down for sparring this {day}? ⚔️` where `{day}` is the calendar event description (default `sunday`). Holiday announcements: day-before `⚠️ Heads up @everyone! Tomorrow is {holiday} (a bank holiday), so there will be no training. Enjoy your day off! 🎉` and same-day `⚠️ Reminder @everyone: Today is {holiday} (a bank holiday), so there will be no training. See you next time! 🎉`, keyed `bank-holiday` / `bank-holiday-today`.
- Same-day holiday handling also **deletes the Google Calendar event**; the dashboard does not own Google Calendar and will not replicate that.

## Sources

- ALE-306 resolution (Linear) — Discord delivery and thread constraints
- ALE-308 resolution (Linear) — Training recurrence and exception semantics
- `github.com/alessandrojcm/dhc-discord-bot` `main.go`, `fly.toml` (read 2026-09-21)
