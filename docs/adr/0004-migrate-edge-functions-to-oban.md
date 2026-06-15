# ADR 0004: Migrate Deno Edge Functions to Oban Workers

**Status:** Accepted  
**Date:** 2026-05-12  
**Deciders:** @alessandrojcm  
**Tags:** oban, edge-functions, queues, background-jobs

## Context

Six Deno edge functions run in the Supabase runtime:

| Function | Role | Trigger |
|----------|------|---------|
| `process-discord` | Queue consumer | HTTP (pgmq read) |
| `process-emails` | Queue consumer | HTTP (pgmq read) |
| `process-workshop-announcements` | Queue processor + producer | HTTP (pgmq read) |
| `stripe-sync` | Cron job | HTTP (pg_cron) |
| `stripe-webhooks` | Webhook handler | Stripe HTTP POST |
| `bulk_invite_with_subscription` | Batch processor | HTTP manual |

These functions run in Deno (separate runtime from the SvelteKit Node.js app), use a different dependency management system (`deno.json`), cannot share types with the rest of the codebase, and have limited tooling for testing and debugging. The queues they consume (`pgmq`) are defined in Postgres but have no observability dashboard, retry policies, or built-in scheduling.

## Decision

All six edge functions are migrated to Oban workers in the Phoenix application:

- **One Oban worker per function**: `Dhc.Discord.Worker`, `Dhc.Email.Worker`, `Dhc.WorkshopAnnouncements.Worker`, `Dhc.StripeSync.Worker`, `Dhc.StripeWebhooks.Worker`, `Dhc.Invitations.BulkInviteWorker`
- **`stripe-sync` becomes an `Oban.Cron` job** (scheduled via cron expression in config).
- **Stripe webhooks** are handled by a Phoenix controller that validates the Stripe signature header (`Stripe.Signature.verify/3`) and enqueues a processing job via `Oban.insert/2`.
- **pgmq is retired.** All queue producers are updated to call `Oban.insert/2` instead of `pgmq.send/2`. The pgmq extension tables remain in the database but are no longer written to.
- **Migration order**: Discord (simplest) → Email → Workshop Announcements → Stripe Sync → Stripe Webhooks → Bulk Invite. This is a per-service big-bang cutover: each worker is built, verified in staging, then the corresponding edge function is deactivated. No dual-write bridge needed — traffic is low enough that draining the remaining pgmq messages naturally is acceptable.

## Consequences

- All background job logic lives in one codebase (Phoenix), one language (Elixir), with one dependency management (`mix.exs`).
- Oban provides: automatic retries with backoff, job uniqueness, concurrency limits, priority queues, and the Oban Web dashboard for observability.
- Stripe webhooks are no longer handled by a separate Deno HTTP endpoint — they route through the same Phoenix pipeline, making error handling, logging, and testing consistent with the rest of the application.
- The edge function directories (`supabase/functions/*`) remain in the repository for historical reference until all functions are migrated and verified.

## Alternatives Considered

- **Keep edge functions.** Rejected because the Deno/Supabase runtime is operationally separate, has different test tooling, and cannot share types with the main application.
- **Migrate pgmq messages to another queue system (RabbitMQ, Redis).** Rejected because Oban sits directly on Postgres (same database Phoenix uses), has zero additional infrastructure, and pgmq-based queues already follow the same pattern (Postgres-backed message queue).
