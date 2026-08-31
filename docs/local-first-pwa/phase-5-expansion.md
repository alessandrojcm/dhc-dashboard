# Handoff — DHC-dashboard Local-first PWA: Phase 5 (entity-by-entity expansion)

## Context

Read the earlier phase handoffs in this directory first, especially `phase-4-pilot-entity.md`. Prerequisite: the pilot entity has proven the full loop (offline read/write, reload offline, reconnect replay, 409 conflict resolution). This phase is the mechanical rollout of the same pattern to the rest of the dashboard.

## Approach

- **No flag-day conversion.** Migrated collections/commands coexist with existing TanStack Query screens. Expand entity-by-entity, screen-by-screen.
- Per entity: (1) confirm Phase 1 server coverage (`lock_version`, conditional writes; `Idempotency-Key` for creates), (2) collection + snapshot hydration, (3) command layer + outbox entries, (4) component migration to live queries, (5) e2e for the offline loop.
- Ordering by value/risk: low-contention CRUD first; high-stakes last.
- **Deferred indefinitely / keep online-only mutations:** Stripe-adjacent flows (payments, refunds — see `apps/web/src/lib/server/api/workshop-refunds*`), attendance, anything where an offline queue is riskier than the UX win. For these the outbox is deliberately not used; the conflict/outbox plumbing can still serve their reads.
- Retire redundant TanStack Query caching only when a complete resource family uses collections.

## Conventions & gotchas

- The existing `phoenix` JS client (channels) is in the frontend deps; push-based invalidation after outbox replay was noted as an open seam but is a **non-goal for v1** — background refresh (hydrate-then-refresh) covers correctness. Revisit only if staleness becomes a complaint.
- Also v1 non-goals: multi-tab sync, Background Sync API reliance, caching personalised SSR HTML.
- Commands from `apps/web`: `pnpm lint`, `pnpm check`, `pnpm test` (unit + e2e). Phoenix side: `mix precommit` (note the `hex.audit` ordering caveat — see phase 1).
- When new conventions settle (e.g. the command-layer pattern, IndexedDB module layout), record them in AGENTS.md / `docs/agents/` and consider an ADR for the final architecture.

## Suggested skills

- `implement`, `tdd` — per-entity slices
- `parallelize-tickets` — if the user wants the entity list run as a ticket graph in parallel
- `to-tickets` / `to-spec` — to publish the remaining expansion as tracker tickets
- `code-review` — review each merged entity migration against standards/spec

## Open questions

- Priority order of entities (needs the user's input — which screens matter most offline).
- Whether high-stakes flows ever get offline writes, or the online-only line is permanent.