# Handoff — DHC-dashboard Local-first PWA: Phase 4 (pilot entity end-to-end)

## Context

Read `phase-1-phoenix-versioning-idempotency.md` and `phase-3-persistence-outbox.md` (same directory) first. Prerequisites: Phase 1 (Phoenix `lock_version`, conditional writes, `Idempotency-Key` for creates) and Phase 3 (persistence/outbox/flusher) must be merged; Phase 2 (PWA shell) strongly recommended so offline reload is demonstrable.

**Agreed architecture:** TanStack DB `createCollection` + `queryCollectionOptions` as the reactive runtime view; IndexedDB for restart durability; REST stays authoritative. Components move from generated `useQuery(queryOptions…)` to collection live queries — mechanical per screen since data shapes are identical. The generated Hey API client stays untouched as transport.

## Tasks

1. Pick a **pilot entity**: simple CRUD, low contention — suggested inventory categories (check `apps/phoenix/lib/dhc_web/controllers/inventory_categories_json.ex` and the generated sdk). Explicitly avoid attendance, payments, Stripe-adjacent flows.
2. Reads: wrap the generated query key + query function verbatim in a `queryCollectionOptions` collection; hydrate from IndexedDB snapshot at client startup; persist snapshot after each successful fetch.
3. Writes: a typed command layer (`updateX`, `createX`, `deleteX`) — components never call generated mutation functions directly. Each command: optimistic collection mutation + `syncState: 'pending'` → outbox entry → flush if online.
   - Create: client-generated UUID as entity id; `Idempotency-Key` = outbox entry id.
   - Delete: local tombstone (`syncState: 'deleted-pending'`), hidden from UI but kept until server ack.
4. Conflict UX: on 409, show the small "your change vs server — [Use server] [Reapply mine]" dialog; reapply re-queues with the new base version.
5. Prove the full loop (e2e + manual): offline edit → reload offline (data still renders) → reconnect → replay → 409 conflict path → resolution.
6. **Before finalising the store choice**, verify the TanStack DB API against current docs — it is young and fast-moving; the report's snippets were hedged. If persistence glue gets painful, TinyBase + `createIndexedDbPersister` is the sanctioned fallback (see phase 3).

## Conventions & gotchas

- TanStack packages in repo: `@tanstack/svelte-query` v6, Hey API already generates `@tanstack/svelte-query` query/mutation options (`packages/api-client/openapi-ts.config.ts`).
- Use the `svelte` MCP tools for Svelte 5 / SvelteKit docs; check TanStack DB docs via `@docs` subagent before writing collection code.
- E2E live in `e2e/` (own AGENTS.md); unit tests vitest from `apps/web`.
- Commands from `apps/web`: `pnpm lint`, `pnpm check`, `pnpm test`.

## Suggested skills

- `implement` — execution
- `tdd` / `prototype` — prototype the collection wiring before migrating the real screen
- `docs` (`@docs` subagent) — current TanStack DB / QueryCollection API verification
- `show-me` — if the user wants the read/write data flow sketched

## Open questions

- Which entity the user ultimately wants as pilot (inventory categories is a suggestion, not decided).
- Whether the command layer should also serve online-only mutations for non-migrated entities, or stay pilot-scoped in this phase.