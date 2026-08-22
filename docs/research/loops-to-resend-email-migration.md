# Loops → Resend transactional email migration

**Research date:** 2026-08-21  
**Question:** How hard is it to migrate a backend integration from the Loops transactional email API (`app.loops.so/api/v1/transactional`) to Resend, and what are the concrete breaking changes between the two APIs?

> **Scope:** Read-only primary-source research. Every claim is cited inline to the official docs, OpenAPI spec, GitHub repo, or hex docs that owns it. No third-party tutorials, blog posts, or AI-generated comparison sites are cited. Statements that cannot be traced to a primary source are marked unverified.

## TL;DR effort verdict

A Loops-to-Resend transactional migration is **moderate effort, mostly a payload-shape rewrite, not an auth or infra rewrite**. The auth scheme (`Authorization: Bearer`), idempotency key header (`Idempotency-Key`, 24h window), and overall rate-limit posture (10 req/sec/team default on both) are nearly identical, and Swoosh ships **official built-in adapters for both providers** (`Swoosh.Adapters.Loops` and `Swoosh.Adapters.Resend`), so the Elixir side can be a near-mechanical adapter swap. The real work is in the four places where the two providers disagree on philosophy:

1. **Templates are hosted in the dashboard on Loops and require a `transactionalId` + `dataVariables` at send time**; Resend supports the same dashboard template model (`template: {id, variables}`) but its idiomatic workflow is code-owned templates — raw `html` / `text` / `react` per send — so the migrator has to decide which side of that line the project lands on, and port every Loops template either way.
2. **Loops can create a marketing Audience contact as a side-effect of a transactional send** via `addToAudience: true`; Resend has no equivalent on the transactional send path — contacts are a separate `/audiences/contacts` API used only for marketing Broadcasts.
3. **Webhook event names and semantics differ** (`email.delivered`/`email.hardBounced`/`email.softBounced`/`email.spamReported` in Loops; `email.sent`/`email.delivered`/`email.bounced`/`email.failed`/`email.opened`/`email.clicked`/`email.complained`/`email.delivery_delayed`/`email.scheduled`/`email.suppressed` in Resend). The 200/400/409 status codes do not map 1:1 — Loops uses `success: bool` + `message` body for non-2xx, Resend uses standard HTTP status codes with typed `error.name` codes (e.g. `validation_error`, `missing_api_key`, `restricted_api_key`).
4. **Attachments are opt-in on Loops** (requires Loops support to enable on the account) and capped at ~4 MB total JSON body; on Resend they are first-class and capped at 40 MB after base64.

Ranking the concrete code changes a caller would face:

| Rank | Change | Effort | Why |
|------|--------|--------|-----|
| 1 | Move every Loops-hosted template body (HTML) into the project (or recreate it in Resend's dashboard) | **High** | Loops's content lives in Loops; the only thing in your code is the `transactionalId` string. If you go code-owned on Resend, you own the markup. |
| 2 | Replace `transactionalId` + `dataVariables` with either `template: {id, variables}` (Resend dashboard) or `html`/`react` (code) per send | **Medium** | The variable interpolation mechanism is the same shape but the field names and source-of-truth flip. |
| 3 | Remap error handling from Loops's `success: bool` + HTTP 200/400 envelope to Resend's HTTP-status-typed errors (`missing_api_key`, `validation_error`, `daily_quota_exceeded`, `validation_error` for unverified-domain) | **Medium** | Same families, different codes and field paths. |
| 4 | Remove or rework `addToAudience: true` logic | **Low–Medium** | If the project relied on this side effect, it needs a separate `POST /audiences/contacts` call. |
| 5 | Rework webhook handlers — different event names and an HMAC scheme that uses different headers | **Medium** | Loops: `webhook-id`/`webhook-timestamp`/`webhook-signature` HMAC-SHA256. Resend: `svix-*` headers via [Standard Webhooks](https://www.standardwebhooks.com/). |
| 6 | Re-issue API keys, verify the sending domain in Resend, and re-baseline the rate-limit environment | **Low (ops)** | Both providers require DNS verification; Resend's defaults are documented; Loops's are too. |
| 7 | Re-test scheduled sends (`scheduled_at` is a first-class field on Resend; Loops does not document a scheduled-send field on `/v1/transactional`) | **Low** | Only matters if the project schedules. |
| 8 | Adapter swap on the Elixir side — `Swoosh.Adapters.Loops` → `Swoosh.Adapters.Resend` (or community `Resend.Swoosh.Adapter`) | **Low** | Both are first-party Swoosh adapters. Provider options change names (`transactional_id`/`data_variables`/`add_to_audience?` → `template`/`tags`/`scheduled_at`/`idempotency_key`). |

## Side-by-side API comparison

| Aspect | Loops | Resend | Source |
|---|---|---|---|
| Base URL | `https://app.loops.so/api` | `https://api.resend.com` | [Loops API intro](https://loops.so/docs/api-reference/intro), [Resend API introduction](https://resend.com/docs/api-reference/introduction) |
| Send endpoint | `POST /v1/transactional` | `POST /emails` | [Loops send-transactional-email](https://loops.so/docs/api-reference/send-transactional-email), [Resend send-email](https://resend.com/docs/api-reference/emails/send-email) |
| Batch endpoint | Not documented for `/v1/transactional` | `POST /emails/batch` (max 100) | [Resend send-batch-emails](https://resend.com/docs/api-reference/emails/send-batch-emails) |
| Auth | `Authorization: Bearer <api-key>` | `Authorization: Bearer re_xxxxx` | [Loops API intro](https://loops.so/docs/api-reference/intro), [Resend API introduction](https://resend.com/docs/api-reference/introduction) |
| Template reference | `transactionalId` (string) | `template: { id, variables }` or inline `html`/`text`/`react` | [Loops send-transactional-email](https://loops.so/docs/api-reference/send-transactional-email), [Resend send-email](https://resend.com/docs/api-reference/emails/send-email) |
| Variable map | `dataVariables: {string\|number\|array-of-objects}` | `template.variables: {string\|number}` (with reserved names + character limits) | [Loops send-transactional-email](https://loops.so/docs/api-reference/send-transactional-email), [Resend send-email](https://resend.com/docs/api-reference/emails/send-email), [Resend template-variables](https://resend.com/docs/dashboard/templates/template-variables) |
| Idempotency | `Idempotency-Key` request header, ≤100 chars, 24h window, returns `409 Conflict` on reuse | `Idempotency-Key` request header, 1–256 chars, 24h window; `invalid_idempotency_key` error otherwise | [Loops OpenAPI spec](https://loops.so/docs/api-reference/send-transactional-email), [Resend send-email](https://resend.com/docs/api-reference/emails/send-email), [Resend errors](https://resend.com/docs/api-reference/errors) |
| Success response | `200 { "success": true }` | `200 { "id": "<uuid>" }` | [Loops send-transactional-email](https://loops.so/docs/api-reference/send-transactional-email), [Resend send-email](https://resend.com/docs/api-reference/emails/send-email) |
| Error response envelope | `200/400/404/405/409` with `success: false` + `message` and optional `error.path`/`error.reason`/`transactionalId` | Standard HTTP status codes + `{ "name": "validation_error", "message": "..." }` body, typed codes | [Loops send-transactional-email](https://loops.so/docs/api-reference/send-transactional-email), [Resend errors](https://resend.com/docs/api-reference/errors) |
| Scheduled send | Not documented for `/v1/transactional` | `scheduledAt: "<natural language \| ISO8601>"` (≤30 days out); not supported in batch | [Resend send-email](https://resend.com/docs/api-reference/emails/send-email), [Resend schedule-email](https://resend.com/docs/dashboard/emails/schedule-email) |
| Attachments | Opt-in (requires Loops to enable on account), base64 in `attachments[]`, ≤4 MB total JSON body | First-class, base64 or hosted, max 40 MB after base64 | [Loops send-transactional-email](https://loops.so/docs/api-reference/send-transactional-email), [Loops attachments](https://loops.so/docs/transactional/attachments), [Resend send-email](https://resend.com/docs/api-reference/emails/send-email) |
| Add-to-audience side effect | `addToAudience: true` on the send | Not available on `/emails`; use `POST /audiences/contacts` separately | [Loops send-transactional-email](https://loops.so/docs/api-reference/send-transactional-email), [Resend audiences introduction](https://resend.com/docs/dashboard/audiences/introduction), [Resend create-contact](https://resend.com/docs/api-reference/contacts/create-contact) |
| Tags | Not documented on `/v1/transactional` | `tags: [{name, value}]` (each ≤256 chars) | [Loops send-transactional-email](https://loops.so/docs/api-reference/send-transactional-email), [Resend send-email](https://resend.com/docs/api-reference/emails/send-email) |
| Reply-to / CC / BCC | Driven by template data variables (`{{replyTo}}` in the editor) | First-class `replyTo`, `cc`, `bcc` fields | [Loops transactional](https://loops.so/docs/transactional), [Resend send-email](https://resend.com/docs/api-reference/emails/send-email) |
| API rate limit | 10 req/sec/team (sends); 60 req/60 sec/team on the content API (`/v1/transactional-emails/*`, etc.) | 10 req/sec/team default (configurable on request) | [Loops API intro](https://loops.so/docs/api-reference/intro), [Loops skills](https://github.com/loops-so/skills/blob/main/skills/loops-api/references/http-api.md), [Resend rate-limit](https://resend.com/docs/api-reference/rate-limit) |
| Email-send rate | 10 emails/sec on free plan, 1000 emails/sec on paid; **excess is queued, not rejected** | No separate send-rate beyond the 10 req/sec/team request cap; daily/monthly quota in addition (`daily_quota_exceeded`, `monthly_quota_exceeded` 429) | [Loops skills](https://github.com/loops-so/skills/blob/main/skills/loops-api/references/http-api.md), [Resend rate-limit](https://resend.com/docs/api-reference/rate-limit) |
| Webhook delivery rate | 10 events/sec; excess queued | Per-endpoint, retry/replay supported | [Loops webhooks](https://loops.so/docs/webhooks), [Resend webhooks introduction](https://resend.com/docs/dashboard/webhooks/introduction) |
| Webhook signing | `webhook-id` + `webhook-timestamp` + `webhook-signature` HMAC-SHA256 of `{webhook-id}.{webhook-timestamp}.{raw-body}` | [Standard Webhooks](https://www.standardwebhooks.com/) (`svix-id`/`svix-timestamp`/`svix-signature`) | [Loops webhooks](https://loops.so/docs/webhooks), [Resend webhooks introduction](https://resend.com/docs/dashboard/webhooks/introduction) |
| Webhook event types | `email.delivered`, `email.softBounced`, `email.hardBounced`, `email.opened`, `email.clicked` (not transactional), `email.unsubscribed` (not transactional), `email.spamReported`, `email.resubscribed`, plus `campaign.email.sent`/`loop.email.sent` | `email.sent`, `email.delivered`, `email.bounced`, `email.complained`, `email.opened`, `email.clicked`, `email.failed`, `email.delivery_delayed`, `email.scheduled`, `email.suppressed`, `email.received`, plus domain/contact events | [Loops webhooks](https://loops.so/docs/webhooks), [Resend event-types](https://resend.com/docs/dashboard/webhooks/event-types) |
| Domain verification | SPF + DKIM + MX records; subdomain recommended; free platform subdomains (`*.vercel.app`, etc.) not allowed | SPF + DKIM + MX; optional custom return-path subdomain, tracking subdomain, TLS mode (`opportunistic`/`enforced`); sandbox `resend.dev` only sends to your own account email | [Loops sending-domain](https://loops.so/docs/sending-domain), [Resend verified domains](https://resend.com/docs/dashboard/domains/introduction), [Resend create-domain](https://resend.com/docs/api-reference/domains/create-domain), [Resend 403 resend.dev](https://resend.com/docs/knowledge-base/403-error-resend-dev-domain) |
| Templating source-of-truth | Dashboard editor (or MJML import); variables bound to data fields | Either (a) dashboard editor with `{{{VARIABLE}}}` syntax + `variables: {…}` map, or (b) code-owned `html`/`text`/`react` per send, or (c) React Email components | [Loops transactional](https://loops.so/docs/transactional), [Resend templates introduction](https://resend.com/docs/dashboard/templates/introduction), [Resend send-email](https://resend.com/docs/api-reference/emails/send-email) |
| Unsubscribe link | **Not included on transactional emails** (by design — these are not marketing) | **Not auto-included on transactional `/emails`**; "topic" opt-in is a Broadcasts/Audiences concept. `List-Unsubscribe` header can be added manually | [Loops transactional](https://loops.so/docs/transactional), [Resend send-email](https://resend.com/docs/api-reference/emails/send-email) |
| Sandbox / test mode | Test by sending to `@example.com` or `@test.com` (event fires, no email sent) | Use `from: onboarding@resend.dev`; the API will 403 with a `validation_error` if you send to anyone other than your own account email until you verify a real domain | [Loops events](https://loops.so/docs/events), [Resend 403 resend.dev](https://resend.com/docs/knowledge-base/403-error-resend-dev-domain) |
| Official Elixir adapter | `Swoosh.Adapters.Loops` (built-in) | `Swoosh.Adapters.Resend` (built-in); community `Resend.Swoosh.Adapter` on hex | [Swoosh.Adapters.Loops hexdocs](https://hexdocs.pm/swoosh/Swoosh.Adapters.Loops.html), [Swoosh.Adapters.Resend hexdocs](https://hexdocs.pm/swoosh/Swoosh.Adapters.Resend.html), [Swoosh README](https://github.com/swoosh/swoosh/blob/main/README.md) |

## Current implementation in this repo

Verified against the code on 2026-08-21 (`apps/phoenix`). **There is no email adapter behaviour** analogous to `Dhc.Discord.Adapter` — the seam that exists today is narrower than a pluggable adapter, but callers are fully decoupled from Loops.

### Caller-facing surface (provider-neutral — must not change)

- Everything sends through one Oban worker, `Dhc.Email.Worker` (`apps/phoenix/lib/dhc/email/workers/worker.ex`, `use Oban.Worker, queue: :emails, max_attempts: 5`). Callers enqueue `%{"email" => ..., "transactional_id" => <friendly name>, "data_variables" => %{string => string \| number}}` via `Worker.new/1 |> Oban.insert/1`.
- Friendly names are whitelisted at `worker.ex:65`: `inviteMember | workshopAnnouncement | workshopRegistration | workshopRegistrationError | magicLink`.
- Context-level entry points: `Dhc.Auth.deliver_magic_link/2` (`apps/phoenix/lib/dhc/auth.ex:363`), `Dhc.Invitations.resend_invitation_emails/1` (`apps/phoenix/lib/dhc/invitations.ex:485`), `Dhc.Invitations.BulkInviteWorker` (`apps/phoenix/lib/dhc/invitations/workers/bulk_invite_worker.ex:280`), and `Dhc.WorkshopAnnouncements.Worker.build_email_jobs/2` (`apps/phoenix/lib/dhc/workshop_announcements/workers/worker.ex:153`). No production path currently enqueues `workshopRegistration`/`workshopRegistrationError`; those names are reserved.

### Loops-specific internals (all private to the worker — this is all a swap touches)

- Default URL `"https://app.loops.so/api/v1/transactional"` overridable via `:dhc, :loops_api_url` (`worker.ex:67–68`).
- Bearer-auth `Req.post` building `%{email, transactionalId, dataVariables}` (`worker.ex:272–311`). The payload never sets `addToAudience` and never sends attachments, so the Resend audience side-effect gap (§3) does not apply here.
- Friendly-name → Loops template-ID resolution from `:dhc, :loops_transactional_ids` (`worker.ex:231–269`), populated from env vars in `config/runtime.exs:144–161` and `config/dev.exs:90–112`, wired to 1Password via `fnox.toml:17–26` (`LOOPS_API_KEY` plus five `*_TRANSACTIONAL_ID` vars).
- Error tuples leak provider naming into Oban results and log/Sentry metadata: `{:error, {:loops_api, status}} \| {:error, {:http_error, exception}}`, plus `:loops_id/:loops_status/:loops_url/:loops_body/:transactional_id` metadata keys allowlisted in Sentry config (`config/config.exs:105–106,172–176`, `runtime.exs:243–246,304–307`) — rename candidates during migration.

### Dev/test seams (already provider-shaped)

- Non-prod environments gate through `Application.get_env(:dhc, :email_dev_mailer, Dhc.Email.DevMailer)` (`worker.ex:206,229`): dev sends via SMTP to Mailpit (`apps/phoenix/dev/dhc/email/dev_mailer.ex`; `mailpit` service in `docker-compose.yml`), tests inject `Dhc.Email.DevMailerStub` (`apps/phoenix/test/support/email_dev_mailer_stub.ex`, selected in `config/test.exs:47`).
- The provider HTTP call itself is stubbed with `Bypass` in `apps/phoenix/test/dhc/email/workers/worker_test.exs` (assertions cover request bodies/headers), so those tests change alongside any payload rewrite.
- There is **no** email-webhook consumer anywhere in the repo today (only Stripe webhooks exist), so the webhook event-name/signature differences (§3) do not bite yet.

### Consequence for a Resend swap

No caller changes are required: the friendly-name + `data_variables` contract maps 1:1 onto Resend's hosted-Templates model (`template: {id, variables}`, above). The work is contained to (1) rewriting the worker's private post/resolve functions, (2) re-pointing config keys/env names, (3) recreating the Loops templates in Resend (dashboard or Templates API), and (4) updating the Bypass-based worker tests. Optionally extract a `Dhc.Email.Adapter` behaviour first, mirroring the house pattern at `apps/phoenix/lib/dhc/discord/adapter.ex`. Adopting Swoosh (`Swoosh.Adapters.Resend` is built-in) is viable but adds a dependency where `Req` is the mandated HTTP client (`apps/phoenix/AGENTS.md`); keeping Req mirrors `Dhc.Stripe.Client`.

## Detailed findings

### 1. Loops Transactional API surface

**Endpoint and base URL.** Loops exposes a single transactional send endpoint at `POST https://app.loops.so/api/v1/transactional`. The full URL is composed of base `https://app.loops.so/api` (from the OpenAPI `servers` block, current `info.version: 1.21.7`) and path `/v1/transactional`. A transactional email must already be created and published in the Loops dashboard before it can be sent. ([Loops send-transactional-email](https://loops.so/docs/api-reference/send-transactional-email), [Loops API intro](https://loops.so/docs/api-reference/intro))

**Auth.** The API uses `Authorization: Bearer <api-key>`. API keys are created from Settings → API in the Loops dashboard; the doc explicitly warns the key must never be used client-side. There is no per-key scope model documented — the same key is used for all endpoints. ([Loops API intro](https://loops.so/docs/api-reference/intro))

**Payload (send).** Required: `transactionalId` (string), `email` (string). Optional: `addToAudience` (bool — if true, the recipient is upserted into your marketing Audience), `dataVariables` (object whose values are strings, numbers, or arrays of `{string|number}` objects; **a missing required variable fails the send**), `attachments[]` (each `{filename, contentType, data}` where `data` is base64; **requires Loops support to enable on the account** and the JSON body must be <4 MB). ([Loops send-transactional-email](https://loops.so/docs/api-reference/send-transactional-email), [Loops attachments](https://loops.so/docs/transactional/attachments))

**Idempotency.** The `Idempotency-Key` request header is optional, capped at 100 characters, and the docs recommend V4 UUIDs. The key is windowed to 24 hours; reuse inside the window returns `409 Conflict` with the `IdempotencyKeyFailureResponse` schema (`{ success: false, message: "Idempotency key already used with a different request body." }`). ([Loops send-transactional-email](https://loops.so/docs/api-reference/send-transactional-email), [Loops send-event](https://loops.so/docs/api-reference/send-event))

**Success response.** `200 OK` with body `{ "success": true }`. There is no provider message-id returned on success — the Loops model treats the message-id as an internal artifact and exposes it on subsequent webhook events. ([Loops send-transactional-email](https://loops.so/docs/api-reference/send-transactional-email))

**Error responses.** Loops uses a small set of typed schemas, all with a `success: false` + `message` shape: `TransactionalSendFailureResponse` (e.g. missing required data variable), `TransactionalFailure2Response` (with `path`), `TransactionalFailure3Response` (with `error: {path, message}`), `TransactionalFailure4Response` (with `error: {path, reason}`), and `TransactionalFailure5Response` (with `transactionalId`). Documented HTTP statuses are `200`, `400`, `404` (transactional not found), `405` (wrong method), and `409` (idempotency key reused). ([Loops send-transactional-email](https://loops.so/docs/api-reference/send-transactional-email))

**Rate limits.** The published profile is:

- **10 requests/second/team** baseline on the send endpoints. Responses include `x-ratelimit-limit` and `x-ratelimit-remaining`; exceeding it returns `429`. ([Loops API intro](https://loops.so/docs/api-reference/intro), [Loops skills HTTP API reference](https://github.com/loops-so/skills/blob/main/skills/loops-api/references/http-api.md))
- **60 requests/60 seconds/team** on the content API (campaigns, components, themes, **transactional-email CRUD** `/v1/transactional-emails/*`, transactional groups, uploads, workflows). This is the limit that hits template-management scripts. ([Loops API intro](https://loops.so/docs/api-reference/intro))
- **Email-send rate** of 10 emails/sec on the free plan and 1000 emails/sec on paid; **excess is queued, not rejected**, which is materially different from Resend's quota-exceeded behavior. ([Loops skills HTTP API reference](https://github.com/loops-so/skills/blob/main/skills/loops-api/references/http-api.md))
- **Webhook delivery rate** of 10 events/sec; excess queued. ([Loops webhooks](https://loops.so/docs/webhooks))
- **Upload rate limit** of 50 uploads/24 hours/team, returns `429` with `maxUploads` and `windowHours` on excess. ([Loops skills HTTP API reference](https://github.com/loops-so/skills/blob/main/skills/loops-api/references/http-api.md))

**Template authoring.** Loops transactional emails are created and **published** in the dashboard editor (or imported from MJML) before they can be sent via the API. Data variables are declared in the editor; a send request that omits a required variable fails (`400 Bad request (e.g. transactional email is not published)` or a `Missing required data variable(s): …` error). Subject / From / Reply-To / CC / BCC can be made dynamic by binding them to data variables in the editor; otherwise they are set in the dashboard and not adjustable per-send. ([Loops transactional](https://loops.so/docs/transactional), [Loops send-transactional-email](https://loops.so/docs/api-reference/send-transactional-email))

### 2. Resend equivalent

**Endpoint and base URL.** Resend exposes `POST https://api.resend.com/emails` for single sends and `POST https://api.resend.com/emails/batch` for up to 100 emails per call. Both require HTTPS; HTTP is not supported. ([Resend API introduction](https://resend.com/docs/api-reference/introduction), [Resend send-email](https://resend.com/docs/api-reference/emails/send-email), [Resend send-batch-emails](https://resend.com/docs/api-reference/emails/send-batch-emails))

**Auth.** `Authorization: Bearer re_xxxxxxxxx`. Resend supports two distinct API-key concepts: a **send-only** key (returns `restricted_api_key` 401 if used for anything other than sending) and a **full-access** key. Swoosh's adapter only uses the send-only key form, which is the recommended production posture. ([Resend send-email](https://resend.com/docs/api-reference/emails/send-email), [Resend errors](https://resend.com/docs/api-reference/errors))

**Payload (send).** Fields: `from` (string, `Name <addr@domain>` form), `to` (string or array, max 50), `cc`/`bcc`, `reply_to`, `subject`, `html` OR `text` OR `react` (a React Email component — Node.js SDK only), `headers` (custom headers), `tags` (array of `{name, value}`, each ≤256 chars), `scheduledAt` (ISO 8601 or natural language; max 30 days out), `attachments[]` (filename + buffer/base64/path, max 40 MB per email after base64), and `template: { id, variables }` (mutually exclusive with `html`/`text`/`react`). When using a `template`, the API will return a `validation_error` if you also include `html`/`text`/`react`. ([Resend send-email](https://resend.com/docs/api-reference/emails/send-email))

**Batch payload.** Up to 100 independent emails per request. `scheduledAt` and attachments (including inline images) are **not supported** on the batch endpoint. ([Resend send-batch-emails](https://resend.com/docs/api-reference/emails/send-batch-emails))

**Idempotency.** `Idempotency-Key` request header, 1–256 characters, expires after 24 hours. Out-of-range keys return `400 invalid_idempotency_key`. The same key + same body in the 24h window is treated as a retry. ([Resend send-email](https://resend.com/docs/api-reference/emails/send-email), [Resend errors](https://resend.com/docs/api-reference/errors))

**Success response.** `200 OK` with body `{ "id": "<uuid>" }`. The id is the Resend message id, used to look up the email in logs and to correlate against webhook events. ([Resend send-email](https://resend.com/docs/api-reference/emails/send-email))

**Error responses.** Standard HTTP status codes (400, 401, 403, 422, 429, 5xx) with `{ "name": "<typed-code>", "message": "<human-readable>" }`. Published typed codes include: `validation_error`, `invalid_idempotency_key`, `missing_api_key`, `restricted_api_key` (both 401 and 403 variants), `suspended_api_key`, `invalid_permission`, `email_above_quota`, plus the rate-limit/quota family `daily_quota_exceeded` and `monthly_quota_exceeded` (429). Two unverified-domain variants return a `validation_error` 403 — the `resend.dev` 403 ("only send testing emails to your own address") and the "domain not verified" 403. ([Resend errors](https://resend.com/docs/api-reference/errors), [Resend 403 resend.dev](https://resend.com/docs/knowledge-base/403-error-resend-dev-domain))

**Rate limits.** Default **10 requests/second/team** (configurable on request, increaseable for trusted senders). When exceeded, the response is `429` and the response headers follow the IETF draft `RateLimit-*` convention (`ratelimit-limit`, `ratelimit-remaining`, `ratelimit-reset`, `retry-after`). **Unlike Loops, exceeding the request rate is rejected, not queued.** In addition, daily and monthly email quotas are enforced and return `daily_quota_exceeded`/`monthly_quota_exceeded` 429s; these are returned with `x-resend-daily-quota` and `x-resend-monthly-quota` response headers. ([Resend rate-limit](https://resend.com/docs/api-reference/rate-limit))

**Template authoring.** Resend offers **two** template models:

- **Dashboard-hosted templates** (create via Templates API or dashboard editor). Use `{{{VARIABLE}}}` syntax with up to 20 declared variables per template; send with `template: { id, variables }`. Variables have a declared `type` and optional fallback value (`fallbackValue`/`fallback_value` depending on SDK); reserved variable names are `FIRST_NAME`, `LAST_NAME`, `EMAIL`, `RESEND_UNSUBSCRIBE_URL`, `contact`, `this`. A template must be **published** before it can be sent (draft edits don't affect already-sent email), and a missing variable with no fallback fails the send with a validation error — both directly parallel Loops's publish + required-data-variable model. ([Resend templates introduction](https://resend.com/docs/dashboard/templates/introduction), [Resend template-variables](https://resend.com/docs/dashboard/templates/template-variables), [Resend send-email](https://resend.com/docs/api-reference/emails/send-email))
- **Code-owned templates**. Pass `html`, `text`, or `react` (a React Email component) inline on the send. The React Email path is the one Resend's own docs recommend ("Resend was built by the same team that created React Email"), and it is Node.js-SDK-only — there is no `react` field on the HTTP API directly, only on the SDK. ([Resend send-email](https://resend.com/docs/api-reference/emails/send-email), [React Email Resend integration](https://react.email/docs/integrations/resend))

### 3. Feature-mapping gaps a migrator must handle

| Gap | Loops behavior | Resend behavior | Migration impact |
|---|---|---|---|
| **Template source-of-truth** | Dashboard editor / MJML import; content lives in Loops | Dashboard editor (with `{{{VAR}}}`), OR code-owned (`html`/`text`/`react`) per send | Decision point: do you (a) recreate templates in the Resend dashboard and keep `template: {id, variables}` semantics, or (b) move markup into the repo as `html_body`/MJML/React components and use `Swoosh.Adapters.Resend` provider options. Option (a) is closer to a 1:1 swap. ([Loops transactional](https://loops.so/docs/transactional), [Resend templates introduction](https://resend.com/docs/dashboard/templates/introduction)) |
| **Audience/contact management** | `addToAudience: true` is a per-send flag on `/v1/transactional`; contacts have custom properties, mailing lists, suppression handling | Resend's Audiences (`/audiences/contacts`) is a **marketing-only** construct used by Broadcasts; transactional `/emails` does not touch it. Contacts have properties, segments, and topic opt-ins | If the project relied on the Loops side-effect to keep a marketing list warm, the migration needs an explicit `POST /audiences/contacts` call (or to drop the marketing audience model entirely). ([Loops send-transactional-email](https://loops.so/docs/api-reference/send-transactional-email), [Resend audiences introduction](https://resend.com/docs/dashboard/audiences/introduction), [Resend create-contact](https://resend.com/docs/api-reference/contacts/create-contact)) |
| **Scheduled send** | Not documented on `/v1/transactional` | First-class `scheduledAt` (natural language or ISO 8601, ≤30 days out); a separate `email.scheduled` webhook event fires | If the project needed to schedule a transactional, it was using an external cron + `/v1/transactional`. On Resend, push the scheduling into the API call. ([Resend send-email](https://resend.com/docs/api-reference/emails/send-email), [Resend schedule-email](https://resend.com/docs/dashboard/emails/schedule-email), [Resend event-types](https://resend.com/docs/dashboard/webhooks/event-types)) |
| **Attachments** | Opt-in (must ask Loops to enable), ≤4 MB JSON body | First-class, max 40 MB after base64; `path` form for hosted files | Resend is strictly more capable. Direct `attachments[]` shape (`{filename, contentType, data}`) is similar; the only change is size limit. ([Loops send-transactional-email](https://loops.so/docs/api-reference/send-transactional-email), [Loops attachments](https://loops.so/docs/transactional/attachments), [Resend send-email](https://resend.com/docs/api-reference/emails/send-email)) |
| **Tags** | Not documented on `/v1/transactional` | `tags: [{name, value}]`, each ≤256 chars, ASCII-only | Tags are new on Resend and do not have a direct Loops counterpart. Useful for filtering in logs. ([Resend send-email](https://resend.com/docs/api-reference/emails/send-email)) |
| **Reply-to / CC / BCC** | Set in editor as data variables on the template | First-class fields on the send payload | Loops requires the template to be authored with `{{replyTo}}` etc. placeholders; Resend takes them as send-time fields. ([Loops transactional](https://loops.so/docs/transactional), [Resend send-email](https://resend.com/docs/api-reference/emails/send-email)) |
| **Webhook event names** | `email.delivered`, `email.softBounced`, `email.hardBounced`, `email.opened`, `email.clicked` (campaign/workflow only, not transactional), `email.unsubscribed` (campaign/workflow only), `email.spamReported`, `email.resubscribed` | `email.sent`, `email.delivered`, `email.bounced`, `email.complained`, `email.opened`, `email.clicked`, `email.failed`, `email.delivery_delayed`, `email.scheduled`, `email.suppressed`, `email.received` | Resend is **more granular** (separate `sent` vs `delivered`, separate `complained` for spam reports, separate `failed` for permanent send errors, separate `delivery_delayed` for transient, separate `scheduled` for queue events). Loops has `softBounced`/`hardBounced` split; Resend collapses soft into `delivery_delayed` and surfaces permanent failure as `bounced`. Loops does not emit a "we accepted the API call" event the way Resend's `email.sent` does. ([Loops webhooks](https://loops.so/docs/webhooks), [Resend event-types](https://resend.com/docs/dashboard/webhooks/event-types)) |
| **Webhook signing** | `webhook-id` + `webhook-timestamp` + `webhook-signature` (HMAC-SHA256 over `{webhook-id}.{webhook-timestamp}.{raw-body}`) | Standard Webhooks (svix): `svix-id`, `svix-timestamp`, `svix-signature` | Both are HMAC-SHA256, but the header names and the prefix scheme differ. Existing signature-verification code must be re-written against the Resend/Standard Webhooks format. ([Loops webhooks](https://loops.so/docs/webhooks), [Resend webhooks introduction](https://resend.com/docs/dashboard/webhooks/introduction)) |
| **Domain verification & sender setup** | SPF + DKIM + MX; subdomain recommended; free subdomains (`*.vercel.app`, `*.netlify.app`, `*.myshopify.com`) not allowed | SPF + DKIM + MX; optional custom return-path subdomain, tracking subdomain, TLS mode (`opportunistic`/`enforced`); sandbox `resend.dev` available but limited to your own account email | Both providers require DNS work; Resend's sandbox `resend.dev` is a near-zero-config dev mode, but it cannot be used in production. ([Loops sending-domain](https://loops.so/docs/sending-domain), [Resend verified domains](https://resend.com/docs/dashboard/domains/introduction), [Resend 403 resend.dev](https://resend.com/docs/knowledge-base/403-error-resend-dev-domain)) |
| **Unsubscribe / compliance** | Loops transactional emails **do not include** an unsubscribe link; Loops's hard-bounce handling also fires a `contact.unsubscribed` event | Resend transactional `/emails` **do not include** an unsubscribe link by default; the `topic` system is a Broadcasts/Audiences concern, not transactional | Conceptually similar — neither provider auto-injects unsubscribe on transactional — but Resend offers a `List-Unsubscribe` header that must be added manually if needed. ([Loops transactional](https://loops.so/docs/transactional), [Resend send-email](https://resend.com/docs/api-reference/emails/send-email)) |
| **Sandbox / test mode** | Send to `@example.com` / `@test.com` addresses — events fire, no email is actually sent | `from: onboarding@resend.dev` works for development, but Resend enforces that recipients must be the account owner's email until a real domain is verified (returns 403 `validation_error` otherwise) | Both are usable as test modes. Resend's is a sender constraint, not a recipient constraint. ([Loops events](https://loops.so/docs/events), [Resend 403 resend.dev](https://resend.com/docs/knowledge-base/403-error-resend-dev-domain)) |
| **Rate-limit posture** | 10 req/sec/team (rejected with 429). Email-send rate separately enforced (10/sec free, 1000/sec paid), **excess queued, not rejected** | 10 req/sec/team default, 429 on excess. **Plus** daily and monthly email quotas; `daily_quota_exceeded`/`monthly_quota_exceeded` 429s | Materially different: a burst of transactional sends on Loops is delayed, not dropped; on Resend it is rejected and the caller has to back off. ([Loops API intro](https://loops.so/docs/api-reference/intro), [Loops skills HTTP API reference](https://github.com/loops-so/skills/blob/main/skills/loops-api/references/http-api.md), [Resend rate-limit](https://resend.com/docs/api-reference/rate-limit)) |
| **Per-key scope model** | Single full-access key per team (no scope separation) | Two key types: send-only and full-access; send-only returns 401/403 `restricted_api_key` if used for anything other than sending | If the project wants a least-privilege key for prod, Resend's send-only key is the right primitive. Loops has no equivalent — any leaked key has full account access. ([Resend send-email](https://resend.com/docs/api-reference/emails/send-email), [Resend errors](https://resend.com/docs/api-reference/errors)) |

### 4. Elixir / Phoenix fit (Swoosh)

**There is an official `Swoosh.Adapters.Resend`** — and there is also an official `Swoosh.Adapters.Loops`. Both are first-party adapters in the Swoosh repo. There is no migration friction on the Elixir side at the adapter level; the work is in the per-call provider options and the templates.

The Swoosh README's "Adapters" section enumerates both:

> "Swoosh supports various email sending adapters including Scaleway, SocketLabs, Gmail, MailPace, SMTP2GO, ProtonBridge, Mailtrap, Mailpit, ZeptoMail, Postal, Lettermint, Resend, and Azure Communication Services. … Adapters for **Loops** and PostUp are also available but are not fully featured services."

And a separate "Third-party Adapters" table lists a community `:resend` hex package with module `Resend.Swoosh.Adapter` (hex docs: [Resend.Swoosh.Adapter](https://hexdocs.pm/resend/Resend.Swoosh.Adapter.html)) — this is a different thing from the built-in `Swoosh.Adapters.Resend`. ([Swoosh README](https://github.com/swoosh/swoosh/blob/main/README.md))

**`Swoosh.Adapters.Loops` (built-in, Swoosh v1.25.1).** Configured with `:api_key`. Provider options:
- `:transactional_id` (required) — the Loops `transactionalId`
- `:data_variables` (map) — the Loops `dataVariables` object
- `:add_to_audience?` (boolean) — the Loops `addToAudience` flag

Notably, the hexdoc states "we need to provide a `from` because it's required by Swoosh. This will be ignored though, since Loops API doesn't support setting a sender." Confirms the template-driven `from` model. ([Swoosh.Adapters.Loops hexdocs](https://hexdocs.pm/swoosh/Swoosh.Adapters.Loops.html))

**`Swoosh.Adapters.Resend` (built-in, Swoosh v1.26.3).** Configured with `:api_key`. Provider options:
- `:tags` (list of `{name, value}` maps) — for categorizing emails
- `:scheduled_at` (ISO 8601 string) — for scheduling
- `:idempotency_key` (string)
- `:template` (map with `:id` and optional `:variables`) — for dashboard templates

Supports both `deliver/2` and `deliver_many/2` (the latter calls Resend's batch endpoint; max 100 emails per call; `scheduled_at` and attachments not supported on batch). Confirms the inline-content-vs-template choice at the Swoosh level. ([Swoosh.Adapters.Resend hexdocs](https://hexdocs.pm/swoosh/Swoosh.Adapters.Resend.html))

**Calling the REST API directly with Req is also viable.** The existing `Dhc.Stripe.Client` in this repo (`apps/phoenix/lib/dhc/stripe/client.ex`) is the pattern. A direct-Req Loops or Resend client would need only:
- `Authorization: Bearer <key>`
- JSON body
- 429 handling with the appropriate `Retry-After`-equivalent (`retry-after` on Resend; `x-ratelimit-*` headers on Loops)
- Error normalization (different per provider)

At DHC scale the rate limits are not the deciding factor; the deciding factor is template ownership. The Swoosh adapter is the lower-friction path because it handles header building, body construction, idempotency-key plumbing, and error parsing consistently. ([Resend rate-limit](https://resend.com/docs/api-reference/rate-limit), [Loops API intro](https://loops.so/docs/api-reference/intro))

### 5. Migration checklist (ordered concrete steps)

1. **Inventory Loops templates.** Pull the list of `transactionalId` values actually used in production. Each one corresponds to a Loops dashboard-edited email that must be re-homed in Resend (either by recreating in the Resend dashboard or by porting the HTML into the repo). ([Loops transactional](https://loops.so/docs/transactional))
2. **Decide template ownership on Resend.** Pick one: (a) dashboard template + `template: {id, variables}` (smallest behavior delta, smallest code change), or (b) code-owned `html`/`text`/`react` (largest change, best long-term DX with React Email). ([Resend templates introduction](https://resend.com/docs/dashboard/templates/introduction))
3. **Add a verified sending domain in Resend** (SPF + DKIM + MX, optionally custom return-path subdomain and tracking subdomain). Note that the sandbox `resend.dev` will 403 on any recipient other than the account owner's email — production sends require a real domain. ([Resend verified domains](https://resend.com/docs/dashboard/domains/introduction), [Resend 403 resend.dev](https://resend.com/docs/knowledge-base/403-error-resend-dev-domain))
4. **Issue a Resend API key.** Prefer a send-only key for prod (least privilege) and a full-access key for admin scripts. ([Resend send-email](https://resend.com/docs/api-reference/emails/send-email))
5. **Migrate the Elixir integration.** `Swoosh.Adapters.Loops` → `Swoosh.Adapters.Resend`. Rename provider options: `:transactional_id` → `:idempotency_key` (or `:template.id`), `:data_variables` → `:template.variables` (or interpolate into `html_body`).
6. **Rewire `addToAudience` semantics.** If the Loops send was also creating marketing contacts, add an explicit `POST /audiences/contacts` call before or after the send — Resend's `/emails` does not touch Audiences. ([Resend audiences introduction](https://resend.com/docs/dashboard/audiences/introduction))
7. **Rewrite the success/error mapping.** Loops returns `{success: true}` or `{success: false, message: ...}`; Resend returns `{id: ...}` on success and `{name: "<code>", message: "..."}` on failure with typed HTTP status codes. Update the call-site pattern matches accordingly. ([Loops send-transactional-email](https://loops.so/docs/api-reference/send-transactional-email), [Resend errors](https://resend.com/docs/api-reference/errors))
8. **Rewire the webhook handler.** Different event names (`email.delivered` is in both, but Resend adds `email.sent`, `email.bounced`, `email.failed`, `email.complained`, `email.delivery_delayed`, `email.scheduled`, `email.suppressed`; Loops splits bounce into `email.softBounced`/`email.hardBounced`). Different signing headers (`webhook-id`/`webhook-timestamp`/`webhook-signature` on Loops; `svix-id`/`svix-timestamp`/`svix-signature` on Resend via Standard Webhooks). ([Loops webhooks](https://loops.so/docs/webhooks), [Resend webhooks introduction](https://resend.com/docs/dashboard/webhooks/introduction), [Resend event-types](https://resend.com/docs/dashboard/webhooks/event-types))
9. **Update retry/backoff logic.** Both providers support the `Idempotency-Key` header (Loops: ≤100 chars, 24h, 409 on reuse; Resend: 1–256 chars, 24h, `invalid_idempotency_key` 400 on out-of-range). Both return 429 on rate-limit excess, but **Loops queues excess email sends, Resend rejects with `daily_quota_exceeded` / `monthly_quota_exceeded`** — review the caller's retry policy. ([Loops send-transactional-email](https://loops.so/docs/api-reference/send-transactional-email), [Resend rate-limit](https://resend.com/docs/api-reference/rate-limit))
10. **If using scheduled sends:** port the logic from external cron + immediate `/v1/transactional` to inline `scheduledAt` on the Resend send. Listen for the new `email.scheduled` webhook if scheduling-state observability is needed. ([Resend schedule-email](https://resend.com/docs/dashboard/emails/schedule-email), [Resend event-types](https://resend.com/docs/dashboard/webhooks/event-types))
11. **If using attachments:** Resend supports them first-class up to 40 MB after base64 (no support-side enablement required). The payload shape is the same `{filename, contentType, data}`. ([Resend send-email](https://resend.com/docs/api-reference/emails/send-email), [Loops attachments](https://loops.so/docs/transactional/attachments))
12. **Test in Resend's sandbox first** (`from: onboarding@resend.dev`, send to your own email). Then re-verify against the production verified domain. ([Resend 403 resend.dev](https://resend.com/docs/knowledge-base/403-error-resend-dev-domain))

## Sources

All cited inline. Listed here as a one-stop reference.

**Loops (official):**

1. [Loops API Introduction](https://loops.so/docs/api-reference/intro) — base URL, auth, rate limits, error handling
2. [Loops Transactional email guide](https://loops.so/docs/transactional) — template authoring, data variables, marketing-vs-transactional rules
3. [Loops Send transactional email (OpenAPI spec)](https://loops.so/docs/api-reference/send-transactional-email) — exact request/response schema
4. [Loops Transactional email API examples](https://loops.so/docs/api-reference/examples/transactional-emails) — code samples for JS/PHP/Ruby/Python/CLI
5. [Loops Send event](https://loops.so/docs/api-reference/send-event) — Idempotency-Key reference
6. [Loops Attachments](https://loops.so/docs/transactional/attachments) — 4 MB cap, base64 shape
7. [Loops Webhooks](https://loops.so/docs/webhooks) — signing scheme, event list
8. [Loops Sending domain](https://loops.so/docs/sending-domain) — SPF/DKIM/MX setup
9. [Loops Events](https://loops.so/docs/events) — `@example.com` / `@test.com` test mode
10. [Loops API skill — HTTP API reference](https://github.com/loops-so/skills/blob/main/skills/loops-api/references/http-api.md) — rate-limit and error table
11. [Loops JavaScript SDK README](https://github.com/Loops-so/loops-js/blob/main/README.md) — `sendTransactionalEmail()` signature
12. [Loops OpenAPI spec](https://app.loops.so/openapi.json) — `info.version: 1.21.7`, `servers.url: https://app.loops.so/api`

**Resend (official):**

13. [Resend API Introduction](https://resend.com/docs/api-reference/introduction) — base URL, HTTPS
14. [Resend Send Email](https://resend.com/docs/api-reference/emails/send-email) — full payload, idempotency, template
15. [Resend Send Batch Emails](https://resend.com/docs/api-reference/emails/send-batch-emails) — up to 100, no scheduled/attachments
16. [Resend Errors](https://resend.com/docs/api-reference/errors) — typed error codes
17. [Resend Usage Limits](https://resend.com/docs/api-reference/rate-limit) — 10 req/sec, daily/monthly quotas
18. [Resend Webhooks introduction](https://resend.com/docs/dashboard/webhooks/introduction) — Standard Webhooks (svix)
19. [Resend Event Types](https://resend.com/docs/dashboard/webhooks/event-types) — full event list
20. [Resend Verified Domains](https://resend.com/docs/dashboard/domains/introduction) — domain setup
21. [Resend Create Domain](https://resend.com/docs/api-reference/domains/create-domain) — API-driven domain creation
22. [Resend 403 resend.dev](https://resend.com/docs/knowledge-base/403-error-resend-dev-domain) — sandbox restrictions
23. [Resend Schedule Email](https://resend.com/docs/dashboard/emails/schedule-email) — `scheduledAt` semantics, 30-day cap
24. [Resend Templates introduction](https://resend.com/docs/dashboard/templates/introduction) — dashboard templates
25. [Resend Template Variables](https://resend.com/docs/dashboard/templates/template-variables) — `{{{VARIABLE}}}` syntax, reserved names
26. [Resend Audiences introduction](https://resend.com/docs/dashboard/audiences/introduction) — Broadcasts/Contacts/Properties/Segments/Topics
27. [Resend Create Contact](https://resend.com/docs/api-reference/contacts/create-contact) — separate contacts API
28. [Resend Create Webhook](https://resend.com/docs/api-reference/webhooks/create-webhook) — programmatic webhook creation
29. [React Email — Resend integration](https://react.email/docs/integrations/resend) — Resend's own recommendation for `react: <Component/>` send shape

**Swoosh (official):**

30. [Swoosh README](https://github.com/swoosh/swoosh/blob/main/README.md) — full adapter list, third-party adapter table
31. [Swoosh Adapters overview](https://github.com/swoosh/swoosh/blob/main/_autodocs/api-reference/adapters-overview.md) — adapter selection guide
32. [Swoosh.Adapters.Loops hexdocs](https://hexdocs.pm/swoosh/Swoosh.Adapters.Loops.html) — `Swoosh v1.25.1`
33. [Swoosh.Adapters.Resend hexdocs](https://hexdocs.pm/swoosh/Swoosh.Adapters.Resend.html) — `Swoosh v1.26.3`
34. [Resend.Swoosh.Adapter hexdocs (community)](https://hexdocs.pm/resend/Resend.Swoosh.Adapter.html) — separate `:resend` hex package
