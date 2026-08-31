# Handoff — DHC-dashboard Local-first PWA: Phase 3 (IndexedDB persistence + outbox + flusher)

## Context

Read `phase-1-phoenix-versioning-idempotency.md` (same directory) first for the programme context. This phase builds the store-agnostic persistence core that phases 4–5 sit on. No UI work here; everything behind interfaces, fully unit-tested.

**Agreed architecture:** local snapshot for reads, durable outbox for writes, REST for reconciliation, server `lock_version` for conflicts. The store (TanStack DB) and the persistence engine must stay swappable — TinyBase + its IndexedDB persister is the fallback if TanStack persistence glue gets painful.

## IndexedDB layout

Database namespaced per env + user id (from the session projection: `principal.id`), purged on sign-out:

```
dhc-local-{env}-{userId}
├── snapshots   // last-known server JSON per query key / entity
├── outbox      // ordered PendingMutation log
└── meta        // schemaVersion, per-entity sync state
```

`schemaVersion` + transactional migration logic from day one. Keep the outbox durable across migrations — cached server records are rebuildable; the outbox is not.

## Interfaces to build

- `LocalPersistence`: `hydrate`, `snapshot(key, data)`, `putMutation`, `pending()`, `ack(id)`, `purge()`.
- Outbox entry shape (agreed): `{ id: uuid, entityType, entityId, operation: 'create'|'update'|'delete', body?, baseVersion?, createdAt, attempts }`.
- Flusher (`flushOutbox`), failure-driven classification:
  - `409` → fetch canonical server entity, mark local record `conflicted` (UI phase 4/5 presents *Use server* / *Reapply mine*).
  - `401` → stop flush, redirect handled by existing auth flow; outbox untouched; retry after next successful session.
  - network / 5xx → keep entry, backoff, continue with other entities.
  - `422`/permanent → mark failed, surface in UI, no infinite retry.
- Ordering: **per-entity** FIFO by `createdAt`; unrelated entities flush concurrently. (Update then delete for the same entity must never arrive reversed.)
- Flush triggers (exposed as a function the app calls): startup, `online` event, after successful authenticated requests, immediately after new mutations while online. Never rely on Background Sync as the only mechanism.

## Conventions & gotchas

- Everything must be client-only (no IndexedDB during SSR). SvelteKit: guard behind browser checks / client-only modules.
- Auth is cookie-based (`_dhc_session`, see `apps/web/src/lib/server/auth.ts`) — replayed mutations need no token handling; just don't persist credentials.
- Unit-test with a fake-indexeddb style shim (needs to be added as dev dep — record in AGENTS.md if so; see `update-agents-md` skill).
- Frontend commands run from `apps/web`: `pnpm lint` (oxlint), `pnpm format` (oxfmt), `pnpm check`, `pnpm test:unit`.

## Suggested skills

- `implement`, `tdd` — the flusher state machine is ideal test-first material
- `codebase-design` — if the persistence/repository seams need sharpening before coding
- `update-agents-md` — after adding any new dev dependency

## Open questions

- Multi-tab: v1 deliberately out of scope (each tab flushes its own outbox; IndexedDB serialises) — confirm acceptable.
- Backoff strategy specifics (fixed vs exponential) — keep simple first.