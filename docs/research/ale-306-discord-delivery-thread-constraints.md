# ALE-306 — Verify Discord delivery and thread constraints

**Research date:** 2026-09-20
**Ticket:** [ALE-306 — Verify Discord delivery and thread constraints](https://linear.app/alessandrojcm/issue/ALE-306/verify-discord-delivery-and-thread-constraints) (child of [ALE-305 — Specify dashboard-owned Discord session notifications](https://linear.app/alessandrojcm/issue/ALE-305/specify-dashboard-owned-discord-session-notifications))
**Scope:** Primary-source facts on Discord REST capabilities, required bot permissions, `allowed_mentions` controls, message-to-thread sequencing, rate limits, error / partial-failure behaviour, and any idempotency mechanism — restricted to the protocol the existing Phoenix adapter must use. No implementation is proposed.
**Dep under test:** Nostrum `~> 0.10.4` (pinned in `apps/phoenix/mix.exs:87`); existing boundary is `Dhc.Discord.Adapter` / `Dhc.Discord.Adapter.Nostrum` (`apps/phoenix/lib/dhc/discord/adapter.ex`, `apps/phoenix/lib/dhc/discord/adapter/nostrum.ex`) with `Nostrum.Api.RatelimiterGroup` + `Nostrum.Api.Ratelimiter` supervised under `Dhc.Discord.RestClientSupervisor`.

---

## 1. Delivery protocol — the two HTTP calls

The Club Session notification sequence is **two distinct REST calls**, not a single atomic op. There is no "send message and create thread" endpoint.

### 1.1 Send the announcement to the fixed channel

```
POST /channels/{channel.id}/messages
```

- Endpoint doc: [Discord — Message Resource → Create Message](https://docs.discord.com/developers/resources/message#create-message).
- Required permissions: `VIEW_CHANNEL` and `SEND_MESSAGES`. May situationally need `SEND_MESSAGES_TTS`. ([Nostrum.Api.Message v0.10.4 — `create/2` moduledoc](https://hex.pm/packages/nostrum/0.10.4/files/lib/nostrum/api/message.ex))
- At least one of `content`, `embeds`, `sticker_ids`, `components`, `files[n]`, `poll`, or `shared_client_theme` must be present. For a text-only roll-call / sparring announcement, `content` is required.
- `content` is capped at **2000 characters**. ([Message Resource](https://docs.discord.com/developers/resources/message))
- Returns the full `message` object on `200 OK`; fires `MESSAGE_CREATE` gateway event. ([Message Resource](https://docs.discord.com/developers/resources/message))
- The returned message is the anchor for the thread call.

### 1.2 Create the thread anchored on that message

```
POST /channels/{channel.id}/messages/{message.id}/threads
```

- Endpoint doc: [Discord — Channels Resource → Start Thread from Message](https://docs.discord.com/developers/resources/channel#start-thread-from-message).
- Returns the new `channel` object on `200 OK`; fires `THREAD_CREATE` and `MESSAGE_UPDATE` gateway events.
- On a `GUILD_TEXT` parent → creates `PUBLIC_THREAD` (type 11). On a `GUILD_ANNOUNCEMENT` parent → creates `ANNOUNCEMENT_THREAD` (type 10). Does **not** work on `GUILD_FORUM` / `GUILD_MEDIA`.
- **The created thread's id equals the source message's id**; Discord documents this as a hard constraint: "a message can only have a single … it." The Nostrum 0.10.4 docs repeat this verbatim: *"The `thread_id` will be the same as the id of the message, as such no message can have more than one thread."* ([Nostrum.Api.Thread v0.10.4 — `create_with_message/4`](https://nostrum.hexdocs.pm/Nostrum.Api.Thread.html))
- Request body parameters (the union of Discord and Nostrum 0.10.4 types):
  - `name` (required, string, 1–100 characters).
  - `auto_archive_duration` (optional, one of `60`, `1440`, `4320`, `10080` minutes). ([Channels Resource](https://docs.discord.com/developers/resources/channel))
  - `rate_limit_per_user` (optional, 0–21600 seconds, i.e. the slowmode applied inside the new thread).
- The thread creation endpoint supports the `X-Audit-Log-Reason` header.
- The channel slowmode (`rate_limit_per_user` on the parent channel) **also applies to thread creation**: "Users can send one message and create one thread during each `rate_limit_per_user` interval." ([Channels Resource — Channel Structure, `rate_limit_per_user` footnote](https://docs.discord.com/developers/resources/channel)). This is unlikely to bite at DHC scale but is a hard ceiling, not a per-bot quota.

### 1.3 Sequence — what the boundary needs to know

- The thread call **requires the parent message id returned by step 1.1**, so the two calls are strictly sequential. There is no pipelined or batched variant.
- A failure between step 1.1 and step 1.2 leaves a posted message with no thread. The boundary must treat that as a recoverable partial state (see §6).
- The Nostrum entry point is `Nostrum.Api.Thread.create_with_message/4`. The send is `Nostrum.Api.Message.create/2` (the deprecated `Nostrum.Api.create_message/2` is forwarded to it). Both are **synchronous** by design — Nostrum documents: *"By default all methods in this module are ran synchronously. If you wish to have async rest operations I recommend you execute these functions inside of a task."* ([Nostrum.Api v0.10.4 — module @moduledoc](https://hex.pm/packages/nostrum/0.10.4/files/lib/nostrum/api.ex))

---

## 2. Required bot permissions in the announcement channel

From the Discord Permissions doc ([Permissions](https://docs.discord.com/developers/topics/permissions)):

| Permission | Bit | What it gates |
|---|---|---|
| `VIEW_CHANNEL` | `1 << 10` | Reading the channel; implicitly denies every other permission if absent. |
| `SEND_MESSAGES` | `1 << 11` | Posting `POST /channels/{id}/messages`. Implicitly denies `MENTION_EVERYONE`, `SEND_TTS_MESSAGES`, `ATTACH_FILES`, `EMBED_LINKS`. |
| `CREATE_PUBLIC_THREADS` | `1 << 35` | `POST /channels/{id}/messages/{id}/threads` when the parent is a `GUILD_TEXT` channel (creates `PUBLIC_THREAD`). |
| `SEND_MESSAGES_IN_THREADS` | `1 << 38` | Posting inside the new thread (only required if the worker ever posts inside the thread, which is **not** in the spec). |
| `MENTION_EVERYONE` | `1 << 17` | Required to actually ping when `@everyone` / `@here` appears in `content`, *and* the `allowed_mentions` includes `"everyone"` (see §3). |

Notes for the boundary:

- The `SEND_MESSAGES` permission is **not** inherited into the thread by default — only `SEND_MESSAGES_IN_THREADS` lets humans post inside the thread. That is not the boundary's concern but is good to record in case follow-up tickets add a thread message.
- `MENTION_EVERYONE` is checked against the **bot's** calculated permissions in the channel, not against `@everyone`'s base — since the [Discord 2022 breaking change](https://github.com/discord/discord-api-docs/discussions/5134). The current DHC bot must therefore be granted `MENTION_EVERYONE` explicitly on the configured announcement channels; the `@everyone` role's permission is no longer enough.
- `VIEW_CHANNEL` + `SEND_MESSAGES` must both be present; absence of `VIEW_CHANNEL` is the common cause of `Missing Access` errors even when `SEND_MESSAGES` checks out. ([Permissions](https://docs.discord.com/developers/topics/permissions))

---

## 3. `allowed_mentions` controls for the `@everyone` toggle

The `@everyone` toggle is a **first-class, additive** feature in the protocol; it is not a separate channel config. Two channels have to agree:

### 3.1 The mention must appear in the rendered message

The Discord docs are explicit:

> "For example, if you want to ping everyone, including it in the `allowed_mentions` field is not enough, the mention format (`@everyone`) must also be present in the content of the message or its components."

Source: [Message Resource — Allowed Mentions Object](https://docs.discord.com/developers/resources/message).

In `content` / embed text, `@everyone` is rendered literally; Discord parses it into a notification based on the allow-list.

### 3.2 The mention must be on the allow-list

The body field is:

```json
"allowed_mentions": {
  "parse": ["everyone", "users", "roles"],   // any subset; "everyone" enables @everyone + @here
  "users": ["<snowflake>", "..."],            // max 100, mutually exclusive with parse
  "roles": ["<snowflake>", "..."],            // max 100, mutually exclusive with parse
  "replied_user": false                       // replies only; default false
}
```

Source: [Message Resource — Allowed Mentions Object](https://docs.discord.com/developers/resources/message); type definition [`APIAllowedMentions` (discord-api-types v10)](https://discord-api-types.dev/api/discord-api-types-v10/interface/APIAllowedMentions).

Rules:

- `parse` is **mutually exclusive** with `users` / `roles`. Mixing them in the same request is a `400 BAD REQUEST`. ([Message Resource](https://docs.discord.com/developers/resources/message))
- Default for "regular messages" (i.e. POST `/channels/{id}/messages` from a bot token) is `{"parse": ["users", "roles", "everyone"]}` — i.e. **mentions parse by default**. The boundary must opt *out* for ordinary roll-call posts that contain no `@everyone` string.
- The `@everyone` / `@here` rendering requires the bot to hold `MENTION_EVERYONE` in the target channel (§2).
- Setting `SUPPRESS_NOTIFICATIONS` (message flag `1 << 12`) suppresses push delivery and shows only a badge — useful as a deliberate "silent posting" toggle but not the requested `@everyone` behaviour. ([Message Resource — JSON Params](https://docs.discord.com/developers/resources/message))

### 3.3 Nostrum 0.10.4 surface

`Nostrum.Api.Message.create/2` accepts `:allowed_mentions` as either:

- an atom — `:all` (default), `:none`, `:everyone`, `:users`, `:roles`; or
- a `{:users, [id]}` / `{:roles, [id]}` tuple; or
- a list combining the above.

`Nostrum.Api.Helpers.prepare_allowed_mentions/1` normalises these to the JSON shape. `:none` becomes `{"parse": []}`, `:everyone` becomes `{"parse": ["everyone"]}`, and lists/IDs merge into `parse` + `users` + `roles` with `Enum.uniq`. If the options are already a map, the helper passes them through unchanged (so the caller can pass the raw JSON shape). Source: [`lib/nostrum/api/helpers.ex` v0.10.4](https://hex.pm/packages/nostrum/0.10.4/files/lib/nostrum/api/helpers.ex).

**Important Nostrum caveat:** the helper merges such that if you pass a list containing both `{:users, [...]}` and `:roles`, the merge *unions* `users` and `roles` keys without complaint. If you pass `{:users, [id]}` *and* `parse: ["users"]` in the same call you would get a `400` from Discord — Nostrum does not validate this on the client side. ([Message Resource — Allowed Mentions Examples](https://docs.discord.com/developers/resources/message))

### 3.4 What the `@everyone` toggle must do at the wire level

- **Off (default for a normal announcement):** set `allowed_mentions: :none` so any incidental `@everyone` in a free-text override cannot ping. This is the safest default.
- **On:** set `allowed_mentions: :everyone` (which renders as `{"parse": ["everyone"]}`) **and** ensure the literal `@everyone` text is present in `content`. The bot must hold `MENTION_EVERYONE` in the channel.

---

## 4. Idempotency — what Discord actually provides

There is **no general-purpose idempotency key**. Discord offers exactly two related primitives, and only one of them survives a network retry:

### 4.1 `nonce` + `enforce_nonce` (Create Message only)

Request body fields on `POST /channels/{id}/messages`:

- `nonce`: integer or string, up to 25 characters. Documented purpose: *"Can be used to verify a message was sent."* ([Message Resource](https://docs.discord.com/developers/resources/message))
- `enforce_nonce`: boolean. *"If true and nonce is present, it will be checked for uniqueness in the past few minutes. If another message was created by the same author with the same nonce, that message will be returned and no new message will be created."* ([Message Resource](https://docs.discord.com/developers/resources/message))

What this gives the boundary:

- A retry of `Message.create/2` with the **same `nonce` and `enforce_nonce: true`** within the de-duplication window will return the original `{:ok, message}` instead of creating a duplicate. This is the **only** Discord-provided idempotency mechanism for sends.
- The "past few minutes" window is not enumerated in the docs; treat it as short and unspecified. Plan for the worker to persist its own nonce long enough that a retry minutes later will still hit the de-dup.
- `enforce_nonce` is **not exposed** by `Nostrum.Api.Message.create/2`. The 0.10.4 options list (`content`, `nonce`, `tts`, `file`/`files`, `embeds`, `allowed_mentions`, `message_reference`, `poll`) does not include `:enforce_nonce`. ([Nostrum.Api.Message v0.10.4 — `create/2` moduledoc](https://hex.pm/packages/nostrum/0.10.4/files/lib/nostrum/api/message.ex)). `Nostrum.Snowflake` is the type of `:nonce`, but the helper does not pin it to a string format — pass a string nonce and Nostrum forwards it. **For idempotency the boundary would need either to (a) talk to `Nostrum.Api.request/4` directly to inject `enforce_nonce: true`, or (b) layer a worker-side `notification_occurrence_id` ↔ Discord `message_id` mapping so retries are recognized and skipped by the worker before hitting Nostrum at all.**

### 4.2 Nothing else

- `enforce_nonce` does not apply to `POST /channels/{id}/messages/{id}/threads`. Thread creation has no idempotency primitive at all. The boundary must rely on **(parent message id ↔ created thread id)** stored durably to detect "thread already created" retries; the response `channel` object carries the thread id (which equals the source message id) so this is straightforward.
- Discord's broader API has no `Idempotency-Key`-style header convention. There is no header documented for either endpoint.

---

## 5. Rate limits

### 5.1 The two endpoints sit in **distinct** buckets

The Discord API computes per-route buckets including HTTP method, and the `X-RateLimit-Bucket` header is shared between routes only when the underlying limit is the same. The `Start Thread from Message` and `Create Message` routes differ in path and method, and historically have been documented as separate limits. Discord staff have acknowledged that bucket IDs can collide between genuinely-distinct routes (see [discord-api-docs#8073](https://github.com/discord/discord-api-docs/issues/8073)) and have stated callers should not rely on the bucket header alone; treat each endpoint as its own rate-limit bucket. Source: [Discord — Rate Limits](https://docs.discord.com/developers/topics/rate-limits).

Practical consequence for the boundary: hitting 429 on a `POST /messages` does not necessarily mean the next `POST /messages/{id}/threads` is also throttled, and vice versa. The worker should consume `Retry-After` from each 429 independently.

### 5.2 Documented known limits at DHC scale

- **Global** rate limit: 50 requests / second across all routes per bot token. ([Rate Limits — Global Rate Limit](https://docs.discord.com/developers/topics/rate-limits))
- **Invalid-request** limit: 10 000 invalid (401 / 403 / 429) responses / 10 minutes → temporary Cloudflare ban. ([Rate Limits — Invalid Request Limit](https://docs.discord.com/developers/topics/rate-limits))
- Per-route limits on `POST /channels/{id}/messages` and `POST /channels/{id}/messages/{id}/threads` are **dynamic** — Discord docs say *"rate limits should not be hard coded into your app"* and explicitly point to response headers. ([Rate Limits](https://docs.discord.com/developers/topics/rate-limits)) Real-world observation from community traffic traces: the messages bucket frequently sits around 5 requests / 5 seconds per channel, but the boundary must read headers rather than rely on that number.

### 5.3 Rate-limit response headers (always read these)

Per the [Rate Limits docs](https://docs.discord.com/developers/topics/rate-limits) and the [Discord Developer Support — My Bot is Being Rate Limited](https://support-dev.discord.com/hc/en-us/articles/6223003921559-My-Bot-is-Being-Rate-Limited) article:

- `Retry-After` — seconds to wait before retrying; returned **only** on 429.
- `X-RateLimit-Limit` — bucket capacity.
- `X-RateLimit-Remaining` — current remaining in the bucket.
- `X-RateLimit-Reset` — epoch seconds when the bucket resets; *"can be inaccurate"* relative to `X-RateLimit-Reset-After` (see [discord-api-docs#5621](https://github.com/discord/discord-api-docs/issues/5621)).
- `X-RateLimit-Reset-After` — relative seconds (may have decimals). **Preferred over `X-RateLimit-Reset`** because it doesn't require clock synchronisation.
- `X-RateLimit-Bucket` — bucket identifier.
- `X-RateLimit-Global` — present only on a 429 if the global rate limit is in effect.
- `X-RateLimit-Scope` — present only on 429; `user`, `global`, or `shared`. `shared` 429s are **not** counted against the invalid-request limit. ([Rate Limits](https://docs.discord.com/developers/topics/rate-limits))

429 body: `{ "message": "...", "retry_after": <float seconds>, "global": <bool>, "code"?: <int> }`.

### 5.4 What Nostrum 0.10.4 does with rate limits

The Nostrum ratelimiter (`Nostrum.Api.Ratelimiter`) is a `:gen_statem` that runs as a singleton per cluster node. Per [`lib/nostrum/api/ratelimiter.ex` v0.10.4](https://hex.pm/packages/nostrum/0.10.4/files/lib/nostrum/api/ratelimiter.ex):

- It parses `X-RateLimit-*` headers, builds a per-bucket queue keyed by `bucket + top-level resource`, and serialises request flow.
- It enforces a **bot-global** budget of 50 calls / second internally (config constants `@bot_calls_per_window 50`, `@bot_calls_time_window :timer.seconds(1)`), independent of the per-route bucket — so it won't blow past Discord's global cap.
- **It automatically requeues a request that hits a 429 with `Retry-After`**, after waiting 10 s (`@retry_429s_after :timer.seconds(10)`) by default for unknown-bucket 429s. The caller of `Message.create/2` therefore sees `{:error, _}` only if the failure is non-rate-limit or non-transient. (Caveat: this is implemented inside the state machine; if the `connection_died` reason happens, the client receives `{:error, {:connection_died, reason}}` and the call is **not** auto-retried.)
- Upstream 502s from Cloudflare do **not** auto-kick the queue — "the ratelimiter will not automatically kick the queue to start further running requests." ([`lib/nostrum/api/ratelimiter.ex` — Failure modes / Upstream errors](https://hex.pm/packages/nostrum/0.10.4/files/lib/nostrum/api/ratelimiter.ex))
- The `Ratelimiter` is a `gen_statem` registered as `Nostrum.Api.Ratelimiter`, started by `Dhc.Discord.RestClientSupervisor` (`apps/phoenix/lib/dhc/discord/rest_client_supervisor.ex:15-16`) with `Nostrum.Api.RatelimiterGroup` as its sibling.

### 5.5 What Nostrum **doesn't** expose

- It does not surface `Retry-After` or the bucket headers to the caller — the caller only sees `{:ok, message}` or `{:error, %Nostrum.Error.ApiError{}}`. So the boundary **cannot** log per-bucket state directly out of the box; the Oban worker must infer retry decisions from the structured `Nostrum.Error.ApiError` it receives and from its own retry-counter.

---

## 6. Error and partial-failure behaviour

### 6.1 Wire-level error envelope

Discord returns structured JSON for almost every non-2xx:

```json
{ "code": 50013, "message": "Missing Permissions", "errors": { ... optional validation detail ... } }
```

with an HTTP status in the 4xx / 5xx range. ([Permissions](https://docs.discord.com/developers/topics/permissions); [discord-api-docs discussions — 50013 is "Missing Permissions"](https://discord.com/developers/docs/topics/opcodes-and-status-codes))

Common status codes the boundary will see for this sequence:

| Status | When |
|---|---|
| `400 BAD REQUEST` | Bad JSON / missing required field / invalid `auto_archive_duration` / mention format invalid / `parse` mixed with `users` or `roles`. |
| `401 UNAUTHORIZED` | Bot token revoked / wrong token — stop sending. ([Rate Limits](https://docs.discord.com/developers/topics/rate-limits)) |
| `403 FORBIDDEN` | `Missing Permissions` (`code: 50013`) — bot lacks `VIEW_CHANNEL` / `SEND_MESSAGES` / `CREATE_PUBLIC_THREADS` / `MENTION_EVERYONE`. Cannot be retried automatically; needs a permission fix. |
| `404 NOT FOUND` | Channel or source message gone. |
| `429 TOO MANY REQUESTS` | Rate limit; requeue via Nostrum. |
| `5xx` (502 / 503 / 504) | Upstream issue — Nostrum does **not** auto-retry these; the worker must surface and re-queue. |

### 6.2 The Nostrum error type

[`Nostrum.Error.ApiError`](https://hex.pm/packages/nostrum/0.10.4/files/lib/nostrum/error/api_error.ex) is:

```elixir
defexception [:status_code, :response]
```

with `response` decoded as either a `String.t()`, an `error` (`%{code, message}`), or a `detailed_error` (`%{code, message, errors}`). The existing `Dhc.Discord.Adapter.Nostrum.normalize_error/1` already wraps this into `Dhc.Discord.ApiError`, but its normalization only forwards `status_code` → `status` and `code`/`message`/`details`. The existing `Adapter.Nostrum` does **not** distinguish:

- the `message_reference` failure case (different status); or
- the `enforce_nonce` collision (200 OK on retry — Nostrum returns the original message, not an error, so there is no signal here).

The current `Adapter.Nostrum.add_guild_member/4` is a good template — it pattern-matches on `%NostrumApiError{status_code: status, response: response}` and reduces to `Dhc.Discord.ApiError`. The new message + thread functions should reuse `normalize_error/1` for parity.

### 6.3 Partial-failure taxonomy

Two-call sequences have three observable terminal states plus one mid-flight failure mode:

1. **Message OK, thread OK** — happy path. Persist `message_id` ↔ `thread_id` (they are equal; see §1.2) ↔ `notification_occurrence_id`.
2. **Message OK, thread 5xx / transient** — message posted, no thread. The boundary's job is to retry thread creation until it lands; the persistence layer must not "post the message again" because that would duplicate the announcement in the channel.
3. **Message 5xx / transient** — neither landed. Standard Oban back-off retry; no durable side-effects yet.
4. **Message OK, thread 403 / 404 / 400 (terminal)** — message is live but the thread can never be created under current configuration. The boundary must surface this as a delivery-state error to operations (see §8), not retry blindly.
5. **Message OK, thread 429** — Nostrum requeues automatically (§5.4). The worker can `await` the `{:ok, channel}` synchronously or wrap in `Task.await`; if Nostrum's requeue times out, the worker still gets `{:error, _}` and must decide whether to back off.

The same `message_id == thread_id` invariant (§1.2) is what makes this tractable: the worker can persist the source message id on success of step 1.1, and on retry only attempt step 1.2.

### 6.4 No Discord-side rollback

There is no API to delete the just-posted message and roll back if the thread call fails. The boundary's only options are:

- (a) delete the message manually with `Nostrum.Api.Message.delete/2` if the failure is terminal and policy says "don't post a threadless announcement", or
- (b) leave the message and post the thread later (idempotent retry).

Either way, the choice is a **product decision** the boundary cannot make for itself.

---

## 7. Other constraints the spec implies

These are not in the ticket's literal question but fall out of the protocol and the spec, and should be flagged for ALE-309 (the delivery-protocol design ticket).

- **Content character budget:** 2000 per message. Roll-call and sparring messages are short today; an officer-supplied free-text override is the only path to a long string. Any long body must be split across the announcement + first-thread-message (the thread can hold another `POST /channels/{thread_id}/messages` of its own 2000 characters — but that requires the bot to post inside the thread, which requires `SEND_MESSAGES_IN_THREADS`).
- **Audit-log reason:** the existing adapter validates audit reasons to reject CR/LF (`apps/phoenix/lib/dhc/discord/adapter/nostrum.ex:101-111`). The thread endpoint accepts `X-Audit-Log-Reason`. The message endpoint does **not** expose one — there's no per-message "reason" because there's no audit-log entry for sending a regular message.
- **Bot identity in the announcement channel:** the bot's *calculated* permissions in the target channel must include `VIEW_CHANNEL`, `SEND_MESSAGES`, `CREATE_PUBLIC_THREADS`, and (if `@everyone` is on) `MENTION_EVERYONE`. This is a deployment-config concern, not a code concern.
- **`SUPPRESS_NOTIFICATIONS` flag** is settable per send (`flags: 1 << 12`) but irrelevant to the `@everyone` toggle; it suppresses push notifications, not the rendered mention.
- **`message_reference`** can be set on `Message.create/2` to reply to a specific message — irrelevant to the first message but relevant if a later ticket wants to reply inside the thread.

---

## 8. Constraints that the spec has not yet fixed (carry into ALE-309)

These are protocol-derived and the researcher's job is only to surface them; ALE-309 owns the decisions.

1. **Idempotency strategy for the message step.** Discord's `enforce_nonce` is **not** exposed by Nostrum `Message.create/2`. The boundary either talks to `Nostrum.Api.request/4` directly or layers a worker-side `(occurrence_id, message_id)` map and skips the call on retry.
2. **Retry policy for the thread step.** Discord has no idempotency for thread creation; the `(parent_message_id → thread_id)` fact is the only durable handle. Worker must read it back before retrying.
3. **Behaviour on message-OK / thread-fail.** Either roll back the message or leave it and keep retrying. The spec doesn't pick.
4. **Message-length overflow on overrides.** If an officer pastes more than 2000 characters, do we truncate, error in preview, or split to a thread message? Out of scope per ALE-305, but the protocol imposes a hard 2000 cap.
5. **Default `allowed_mentions` posture for non-`@everyone` posts.** The Nostrum `Message.create/2` default is `:all`, which would silently ping any role/user mention an officer types into a free-text override. Set `:none` by default unless `@everyone` is explicitly on.
6. **Audit-log reason format for thread creation.** The existing adapter rejects CR/LF. The thread call accepts a reason — the boundary should decide what string to use (e.g. `"Club Session: #{session_kind} #{occurrence_date}"`).
7. **DHC deployment-config required permissions on the announcement channels.** The bot currently has *roster + doctor* permissions (`apps/phoenix/lib/dhc/discord/adapter/nostrum.ex`). For session notifications it additionally needs `SEND_MESSAGES`, `CREATE_PUBLIC_THREADS`, and conditionally `MENTION_EVERYONE` on the deployment-configured channels — verify with the DHC admin that those are granted and that the bot's role position does not block them.

---

## 9. Quick reference

| Question | Answer | Source |
|---|---|---|
| One endpoint for message + thread? | **No.** Two sequential calls. | [Message Resource](https://docs.discord.com/developers/resources/message), [Channels Resource](https://docs.discord.com/developers/resources/channel) |
| Required perms to send? | `VIEW_CHANNEL`, `SEND_MESSAGES` | [Permissions](https://docs.discord.com/developers/topics/permissions) |
| Required perms to create thread? | `CREATE_PUBLIC_THREADS` | [Permissions](https://docs.discord.com/developers/topics/permissions) |
| `@everyone` toggle mechanism? | `allowed_mentions.parse = ["everyone"]` **and** literal `@everyone` in content **and** `MENTION_EVERYONE` perms | [Message Resource — Allowed Mentions](https://docs.discord.com/developers/resources/message) |
| Default `allowed_mentions` for a bot send? | `{"parse": ["users", "roles", "everyone"]}` — i.e. all mentions parse | [Message Resource — Allowed Mentions](https://docs.discord.com/developers/resources/message) |
| Idempotency mechanism? | `nonce` + `enforce_nonce: true` on the message only; no primitive for the thread | [Message Resource](https://docs.discord.com/developers/resources/message) |
| `enforce_nonce` exposed by Nostrum 0.10.4? | **No.** Options list omits it. | [Nostrum.Api.Message v0.10.4](https://hex.pm/packages/nostrum/0.10.4/files/lib/nostrum/api/message.ex) |
| Thread id == message id? | **Yes**, by Discord and Nostrum docs. | [Channels Resource](https://docs.discord.com/developers/resources/channel), [Nostrum.Api.Thread v0.10.4](https://nostrum.hexdocs.pm/Nostrum.Api.Thread.html) |
| Thread creation on announcement channel? | Creates `ANNOUNCEMENT_THREAD` (type 10). | [Channels Resource — Start Thread from Message](https://docs.discord.com/developers/resources/channel) |
| Content cap? | 2000 chars per message. | [Message Resource](https://docs.discord.com/developers/resources/message) |
| Auto-archive options? | 60 / 1440 / 4320 / 10080 minutes. | [Channels Resource](https://docs.discord.com/developers/resources/channel) |
| Global rate limit? | 50 req/s per bot token; enforced by Nostrum's internal state machine. | [Rate Limits](https://docs.discord.com/developers/topics/rate-limits) |
| Per-route limits? | Dynamic; never hardcode. Read `X-RateLimit-Reset-After` over `X-RateLimit-Reset`. | [Rate Limits](https://docs.discord.com/developers/topics/rate-limits), [discord-api-docs#5621](https://github.com/discord/discord-api-docs/issues/5621) |
| Nostrum auto-retries 429? | **Yes**, internally requeues with `Retry-After`; default 10 s for unknown-bucket 429s. | [Nostrum.Api.Ratelimiter v0.10.4](https://hex.pm/packages/nostrum/0.10.4/files/lib/nostrum/api/ratelimiter.ex) |
| Nostrum auto-retries 5xx? | **No.** Surface to the worker. | [Nostrum.Api.Ratelimiter v0.10.4 — Failure modes](https://hex.pm/packages/nostrum/0.10.4/files/lib/nostrum/api/ratelimiter.ex) |
| Error envelope on 4xx/5xx? | JSON `{ code, message, errors? }`. `code: 50013` = Missing Permissions. | [Permissions](https://docs.discord.com/developers/topics/permissions) |
| Nostrum error type? | `Nostrum.Error.ApiError{status_code, response}`. Already wrapped by `Dhc.Discord.ApiError` in the local adapter. | [Nostrum.Error.ApiError v0.10.4](https://hex.pm/packages/nostrum/0.10.4/files/lib/nostrum/error/api_error.ex) |
| Audit-reason support on thread call? | **Yes** — `X-Audit-Log-Reason` header. | [Channels Resource — Start Thread from Message](https://docs.discord.com/developers/resources/channel) |
| Sync vs async Nostrum calls? | Synchronous by default; run inside `Task` if you need async. | [Nostrum.Api v0.10.4](https://hex.pm/packages/nostrum/0.10.4/files/lib/nostrum/api.ex) |

---

## Sources cited

1. Discord — [Message Resource](https://docs.discord.com/developers/resources/message)
2. Discord — [Channels Resource](https://docs.discord.com/developers/resources/channel)
3. Discord — [Rate Limits](https://docs.discord.com/developers/topics/rate-limits)
4. Discord — [Permissions](https://docs.discord.com/developers/topics/permissions)
5. Discord Developer Support — [My Bot is Being Rate Limited!](https://support-dev.discord.com/hc/en-us/articles/6223003921559-My-Bot-is-Being-Rate-Limited)
6. discord-api-types v10 — [`APIAllowedMentions`](https://discord-api-types.dev/api/discord-api-types-v10/interface/APIAllowedMentions) and [`AllowedMentionsTypes`](https://discord-api-types.dev/api/discord-api-types-v10/enum/AllowedMentionsTypes)
7. discord-api-docs issue [5621](https://github.com/discord/discord-api-docs/issues/5621) — `X-RateLimit-Reset` vs `X-RateLimit-Reset-After`
8. discord-api-docs issue [8073](https://github.com/discord/discord-api-docs/issues/8073) — shared bucket IDs across distinct routes
9. discord-api-docs PR [1396](https://github.com/discord/discord-api-docs/pull/1396) — original `allowed_mentions` design
10. discord-api-docs discussion [5134](https://github.com/discord/discord-api-docs/discussions/5134) — `MENTION_EVERYONE` / `USE_EXTERNAL_EMOJIS` change for interactions/webhooks
11. Nostrum v0.10.4 — [`Nostrum.Api`](https://hex.pm/packages/nostrum/0.10.4/files/lib/nostrum/api.ex)
12. Nostrum v0.10.4 — [`Nostrum.Api.Message`](https://hex.pm/packages/nostrum/0.10.4/files/lib/nostrum/api/message.ex)
13. Nostrum v0.10.4 — [`Nostrum.Api.Thread` (hexdocs)](https://nostrum.hexdocs.pm/Nostrum.Api.Thread.html)
14. Nostrum v0.10.4 — [`Nostrum.Api.Ratelimiter`](https://hex.pm/packages/nostrum/0.10.4/files/lib/nostrum/api/ratelimiter.ex)
15. Nostrum v0.10.4 — [`Nostrum.Api.Helpers`](https://hex.pm/packages/nostrum/0.10.4/files/lib/nostrum/api/helpers.ex)
16. Nostrum v0.10.4 — [`Nostrum.Error.ApiError`](https://hex.pm/packages/nostrum/0.10.4/files/lib/nostrum/error/api_error.ex)
17. Local — [`apps/phoenix/lib/dhc/discord/adapter.ex`](apps/phoenix/lib/dhc/discord/adapter.ex)
18. Local — [`apps/phoenix/lib/dhc/discord/adapter/nostrum.ex`](apps/phoenix/lib/dhc/discord/adapter/nostrum.ex)
19. Local — [`apps/phoenix/lib/dhc/discord/rest_client_supervisor.ex`](apps/phoenix/lib/dhc/discord/rest_client_supervisor.ex)
20. Local — [`apps/phoenix/lib/dhc/discord.ex`](apps/phoenix/lib/dhc/discord.ex)
21. Local — [`apps/phoenix/mix.exs`](apps/phoenix/mix.exs) (`{:nostrum, "~> 0.10.4"}` at line 87)
22. Prior DHC research — [`docs/research/ale-203-discord-oauth-guild-roster-capabilities.md`](docs/research/ale-203-discord-oauth-guild-roster-capabilities.md)
23. Prior DHC research — [`docs/research/ale-225-elixir-discord-library.md`](docs/research/ale-225-elixir-discord-library.md)
