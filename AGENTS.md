# PROJECT KNOWLEDGE BASE

**Status:** Phoenix + Ecto + Oban migration complete

## Overview

Dublin Hema Club dashboard monorepo: the SvelteKit 2.x + Svelte 5 frontend lives in `apps/web`, alongside the Phoenix + Ecto + Oban backend in `apps/phoenix`. Root pnpm/mise commands delegate to the frontend workspace, which consumes Phoenix through the typed OpenAPI client in `packages/api-client`.

Invitation Acceptance is owned by `Dhc.Onboarding.Acceptance` (GH-507) behind an **opaque handle** — the signed `_dhc_onboarding_acceptance` cookie value — and every browser-facing operation returns a closed safe view whose `state` is the discriminator; never return an Ecto schema, attempt id, operation token, confirmation token, or provider subject from it. Every authoritative read of Continuation/Attempt/Invitation/Claim rows goes through `Acceptance.Locked` (principal advisory → subject advisory → Continuation → Attempt → Invitation → Claims): add a transition inside a `with_locked`/`lock!` block rather than writing a new `FOR UPDATE` query. Synchronous `submit_payment/2`, explicit `retry/1`, and worker `recover/1` converge on the private `progress/2` (lease in one transaction, Stripe outside it, `owned_fence!/1` before every write) — do not add a second Stripe progression path. Pricing is handle-bound too (`preview_pricing/2`, `GET /onboarding/invitation-acceptance/pricing`, `paymentReady` only per ADR-0019): the public Invitation id is never workflow authority, so do not reintroduce an `/invitations/:id/pricing`-style read. `Dhc.Onboarding` keeps only Invitation-level operations. See the Invitation Acceptance row in `docs/agents/where-to-look.md`.

JavaScript/TypeScript linting uses the shared root Oxlint config through the `apps/web` and `packages/api-client` workspace scripts; formatting uses Oxfmt from `apps/web`. Root `pnpm` and mise tasks delegate to those workspace scripts.

Phoenix `mix precommit` runs `hex.audit` before dependency-provided Mix tasks; under the pinned Mix version, running Credo or Reach first unloads the archived Hex task from the current process.

Dev data can include pending direct member invitations through `mise run seed-invitations [count]`; see the Seeds section in `docs/agents/commands.md` for all seed tasks.

Invitation pricing tiers use backend-applied Stripe coupon IDs, not customer-facing promotion codes; see the invitation pricing tier note in `docs/agents/notes.md` for coupon configuration and E2E conventions.

Target Inventory Item operations live on `/api/inventory/items*` under the one `Inventory` tag since ALE-289 deleted the legacy slice and moved them onto the freed URLs (slice `inventoryItems.*`); those reads are operator-only by design. The member-facing catalog and own-loan operations (`/api/inventory/catalog/items*`, `/api/inventory/loans/mine*`) are a **separate read model**, not a role variant of the operator viewer — member rows cannot express container, notes, or maintenance facts at all. See the Inventory Item and member catalog rows in `docs/agents/where-to-look.md` before editing the API contract.

The generated API client carries a pnpm patch on `@hey-api/openapi-ts` (`patches/`, recorded in `pnpm-workspace.yaml`): ky v2 eagerly consumes error response bodies into `HTTPError.data`, so the unpatched generated client throws `TypeError: body stream already read` and every `error.errors?.detail` UI falls back. The patch reuses the pre-parsed body through the same interceptor pipeline; `pnpm --filter @dhc/api-client api:generate` (and postinstall) regenerate with it applied.

Loan commands are split domain-seam-first: `Dhc.Inventory.OperatorLoans` (ALE-296) writes every operator transition as durable rows and emits **no notifications**. The HTTP exposure (ALE-298) attaches keyed notifications *after* the command returns via `Dhc.Inventory.notify_loan_transition/2` → `create_keyed/3`. Wiring `Dhc.Notifications.create/2` into a loan transition is the specific mistake that split exists to prevent. See the operator loan and operator-loan-exposure rows in `docs/agents/where-to-look.md`.

Notifications that can be retried must go through the keyed seam `Dhc.Notifications.create_keyed/3` (ALE-287), not `create/2`, which stays at-least-once for existing unkeyed callers. The key names the logical event; uniqueness is `(principal_id, notification_key)`, so one event notifies many recipients from one key. Loan reminders (`Dhc.Inventory.LoanReminders`) treat the durable ledger **as** the schedule rather than scheduling a job per reminder: one pass computes at most one owed occurrence per loan, so delivery and reconciliation are the same code path and a missed tick self-heals. `due_on_revision` is derived from the loan's due date, which is why a due-date edit reschedules reminders without any write on the transition path — the reason loan commands stay reminder-free. See the keyed-notification and loan-reminder rows in `docs/agents/where-to-look.md`.

The operator loan queue (`Dhc.Inventory.OperatorLoanQueue`, ALE-297) is a lock-free, actor-free **read model** over those rows: bucket counts are `length(rows)` of the bucket beside them rather than a second aggregate query, so the queue is deliberately unpaginated. It projects loans through the now-public `OperatorLoans.operator_view/2` instead of rebuilding the shape, which is the rule to preserve when adding a bucket or field — a queue row and the operator detail read must not be able to disagree. See the operator loan queue row in `docs/agents/where-to-look.md`.

`mix gen.controllers` scaffolds one controller + JSON renderer + contract test per **slice** — the `operationId` prefix — not per tag, so a domain keeps one tag and one URL root while being served by several controllers (the `Inventory` tag owns `inventoryStructure` and `inventoryOperatorItems`). Every operation needs an `operationId` of `<slice>.<action>` whose prefix underscores to the controller filename, and `mise run api-gen` must stay idempotent (only `skip` lines, no new files). See ADR 0003 and the `mix gen.controllers` gotchas in `docs/agents/notes.md`.

## Navigation

- Structure: [docs/agents/structure.md](docs/agents/structure.md)
- Where to look: [docs/agents/where-to-look.md](docs/agents/where-to-look.md)
- Migration notes: [docs/agents/migration-notes.md](docs/agents/migration-notes.md)
- Critical patterns: [docs/agents/critical-patterns.md](docs/agents/critical-patterns.md)
- Anti-patterns: [docs/agents/anti-patterns.md](docs/agents/anti-patterns.md)
- Commands: [docs/agents/commands.md](docs/agents/commands.md)
- Tech stack: [docs/agents/tech-stack.md](docs/agents/tech-stack.md)
- Services & roles: [docs/agents/services-and-roles.md](docs/agents/services-and-roles.md)
- Notes: [docs/agents/notes.md](docs/agents/notes.md)
- Visual previews: [docs/agents/visual-previews.md](docs/agents/visual-previews.md)
- Frontend design system: [design-system/dublin-hema-club/MASTER.md](design-system/dublin-hema-club/MASTER.md)

## Agent skills

- Issue tracker: Linear issues via `linctl`; see [docs/agents/issue-tracker.md](docs/agents/issue-tracker.md).
- Triage labels: canonical labels/status strings; see [docs/agents/triage-labels.md](docs/agents/triage-labels.md).
- Domain docs: single-context monorepo with `CONTEXT.md` and `docs/adr/`; see [docs/agents/domain.md](docs/agents/domain.md).

## See also

`CONTEXT.md`, `docs/adr/`, `supabase/AGENTS.md`, `e2e/AGENTS.md`
