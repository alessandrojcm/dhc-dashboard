# ALE-428: Resend offer-round batching handoff

## Task and source of truth

Implement [ALE-428 — Batch workshop offer-round Contact emails through Resend](https://linear.app/alessandrojcm/issue/ALE-428/batch-workshop-offer-round-contact-emails-through-resend).
The Linear issue owns the detailed requirements and acceptance-test matrix;
read it before implementation. This file is the repository entry point for
the next session, not a second specification.

The user agreed to batching **Beginners' Workshop offer-round Contact emails
only**, rather than introducing a general transactional-email batching system.
Both the pay and workshop-credit confirmation variants are included. Fast-track,
resends, login links, invitations and other email occasions remain individual.

## Starting state

Use `but` for version-control writes. The prerequisite implementation is on
`fix/provider-delivery-sentry`:

- `9e8ed04b`: shared Resend request gate, email/Sentry privacy, safe Stripe
  diagnostics and Discord join safeguards.
- `90f93549`: correction to an independently failing, date-sensitive test.

If that branch has not landed, stack the new implementation above it. Preserve
its changes rather than implementing another limiter or redaction path.
Deployment was not performed during this session.

The existing limiter protects the account across nodes: one request per 125 ms
(8/s), with a shared cooldown after a provider 429. It covers individual sends,
batch sends and receiving API reads. Retain it: batching reduces request count
but does not eliminate provider rate limits.

## First code to read

Paths below are relative to `apps/phoenix`:

| Owner | Starting point |
| --- | --- |
| Offer-round command | `lib/dhc/beginners_workshops/commands/batches.ex`: `create_batch/4`, `contact_all/4`, shared `contact/4` |
| Intake Email preparation and ledger | `lib/dhc/beginners_workshops/intake_emails.ex`: `deliver/5`, `queue/4`, plus `intake_emails/` |
| Existing individual delivery | `lib/dhc/email/workers/worker.ex` |
| Swoosh transport and idempotency header | `lib/dhc/email/mailer.ex`, `lib/dhc/email/api_client.ex` |
| Account-wide pacing | `lib/dhc/resend/rate_limit.ex` |
| Existing batch-send example | `lib/dhc/member_announcements/delivery.ex` |
| Final Sentry filtering | `lib/dhc_web/sentry_privacy.ex` |

Also read the root and Phoenix `AGENTS.md`, the automatic Batches and Intake
Email entries in `docs/agents/where-to-look.md`, and ADRs 0021, 0022 and 0029.

## Implementation direction

Start with a failing request-level test: an offer round with several people
must issue one Resend batch request, preserving each person's own message and
ledger occasion, rather than one request per person.

The important distinction is between a domain **offer round** and a provider
**delivery batch**. Group the known round at enqueue time into immutable chunks
of at most 100 envelopes. Do not regroup arbitrary existing Oban jobs.

Keep `IntakeEmails.deliver/5` as the owner of recipient selection, pay/confirm
variants, rendering, links, Reply-To credentials and ledger writes. Extend its
queue planning narrowly; keep the shared fast-track Contact path individual.
Creation and delivery enqueue must commit together through the existing
Commands transaction. Provider HTTP happens afterward, without domain locks.

Freeze each chunk's membership, order and request-affecting envelope before
its first request. Retry the identical payload with the identical idempotency
key, including after ambiguous failures. Preserve credential sealing and the
existing queued single-email jobs. Extend Sentry filtering to any new worker
and its nested arguments before enabling batch error reporting.

The main technical decision is validation failure handling. Verify the current
[Resend batch API](https://resend.com/docs/api-reference/emails/send-batch-emails)
and the installed Swoosh adapter's capabilities. Do not assume per-item success
semantics. Splitting a rejected batch requires proof that none of its messages
were accepted; a timeout is not that proof. Account for the provider's 24-hour
idempotency window and the existing 24-hour Intake credential seal.

## Verification and handback

Use the full acceptance matrix in ALE-428, including chunk boundaries,
personalization, rollback/concurrency, frozen retries, permanent failures,
credential expiry and actual Oban/Sentry reporting. Keep Member Announcements
and every out-of-scope email path unchanged.

Run focused tests, `mix credo --all` and `mix precommit` from `apps/phoenix`.
At handoff, the preceding implementation had **2,883 passing tests, 4 excluded**,
with lint, architecture and compilation passing. Precommit still exited nonzero
because of existing Bandit/JOSE audit advisories; report them separately rather
than suppressing them.

For this machine, Docker tests needed
`DOCKER_HOST=unix:///Users/alessandrojcm/.colima/default/docker.sock` and
`TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock`. Discover the actual
Docker configuration when running elsewhere.

Return the persistence and validation strategy, test results, and any migration
or deployment steps. Verify against local stubs; do not send real club emails.
