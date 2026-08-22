# Swoosh Is the Email Transport Seam

**Status:** Accepted  
**Date:** 2026-08-22  
**Tags:** email, swoosh, oban, dependencies

## Context

Transactional emails flow through `Dhc.Email.Worker`, which today hand-rolls both halves of delivery: a `Req.post` to the Loops API in prod, and `Dhc.Email.DevMailer` — a hand-built RFC 5322 message over `gen_smtp` to Mailpit — in non-prod. Tests stub these with a `DevMailerStub` app-env swap plus Bypass HTTP stubs. A migration to Resend is planned, and apps/phoenix/AGENTS.md mandates Req as the only HTTP client while `.reach.exs` enforces it for `Dhc.*` code. The house pattern for fencing a vendor library (`Dhc.Discord.Adapter`) wraps it in a semantic behaviour.

Swoosh ships first-party adapters for Loops, Resend, and Mailpit (HTTP), plus test adapters and assertions. Unlike Nostrum, Swoosh is designed to be configured rather than wrapped: provider choice is runtime config on a single mailer, not invasive API surface.

## Decision

Adopt Swoosh as the only transport layer for transactional email. No bespoke `Dhc.Email.Adapter` behaviour is introduced: the Oban Worker remains the domain-facing boundary (Email Kind + data variables), builds `%Swoosh.Email{}`, and calls one mailer whose adapter is chosen per environment by configuration. The Loops→Resend cutover is a config flip, not new code.

Supporting choices:

- `config :swoosh, :api_client, Swoosh.ApiClient.Finch` with a named `Swoosh.Finch` child — Finch is already a production dependency, keeping Hackney out of prod.
- Non-prod delivers via `Swoosh.Adapters.Mailpit` (HTTP), deleting `DevMailer` and the `gen_smtp` dependency. Dev failure-swallowing semantics are preserved in configuration around delivery.
- Tests use `Swoosh.Adapters.Test` / `Swoosh.TestAssertions`, replacing `DevMailerStub` and Bypass request-body assertions.
- Sends carry `Idempotency-Key: oban-<job.id>`; deterministic provider validation failures (e.g. missing template variables) are discarded immediately rather than retried, while rate limits and network errors retry with backoff.
- This decision documents the exception to the Req-only HTTP-client rule for the email transport seam and updates apps/phoenix/AGENTS.md accordingly. Application code continues to use Req everywhere else.

## Consequences

- One production dependency (`:swoosh`) is added; `gen_smtp` becomes dev-only-then-deleted.
- Provider swaps, retries, idempotency, and error normalization move out of hand-rolled worker internals into Swoosh plus configuration.
- The Worker's public job contract (recipient, Email Kind, data variables) does not change; queued jobs survive the refactor.
- Reach rules need no change (Swoosh internals are outside `Dhc.*`), but the AGENTS.md HTTP-client guidance gains a documented exception.

## Considered options

- **Req-direct provider client** (mirroring `Dhc.Stripe.Client`). Viable — the Resend send is one JSON POST — but it would re-implement provider payload/error handling, the dev SMTP relay, and test tooling that Swoosh provides for free, and leave the team maintaining three bespoke email paths.
- **A `Dhc.Email.Adapter` behaviour wrapping Swoosh.** Rejected as ceremony: Swoosh's adapter selection already is the seam, and a second behaviour beneath the Worker adds indirection without adding callers.
