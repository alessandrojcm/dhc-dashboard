# Optimistic Concurrency and Idempotent Creates (Phase 1 Contract)

**Status:** Accepted
**Date:** 2026-08-31
**Tags:** api, concurrency, http, local-first-pwa, idempotency
**Parent issue:** ALE-264

## Context

The dashboard is gaining offline/local-first PWA support (see
`docs/local-first-pwa/phase-1-phoenix-versioning-idempotency.md`). When a
browser queues writes offline and replays them hours later, the API today
offers no defense against two failure modes:

1. **Lost updates.** Every PATCH is a blind last-write-wins overwrite; an
   offline edit based on a stale read silently clobbers concurrent server-side
   changes.
2. **Duplicate creates.** A create whose response was lost is re-sent by the
   outbox, producing a second record.

The server must provide a version witness for conflict detection and a
durable replay memory for duplicate suppression.

## Decision

### Versioning: RFC 9110 conditional requests with ETag/If-Match

Every mutable entity gains a `lock_version` column (integer, NOT NULL,
default 1; migration adds it to inventory items/containers/categories,
workshops and registrations, waitlist entries, member and user profiles,
settings — payment/refund/durable-workflow tables excluded). `Ecto.Changeset.
optimistic_lock/3` is wired into every update path, including `Ecto.Multi`
flows (the inventory item update Multi carries the lock on the item
changeset) and command endpoints (move, maintenance, attendance, lifecycle
transitions). A stale write raises `Ecto.StaleEntryError`.

The version is exposed wire-level as `lockVersion` in response bodies and as
a strong `ETag` header on single-entity responses whose value is derived
directly from `lock_version` (e.g. `"7"`). Mutating endpoints honor
`If-Match` and fail stale writes with `412 Precondition Failed` carrying
the current server entity; single-entity GETs honor `If-None-Match` with
`304 Not Modified`.

**ETag/If-Match over body-only versioning.** A body-only `lockVersion`
field would force clients to invent a non-standard compare-and-swap header
to actually enforce it. RFC 9110 conditional requests give the same
guarantee with standard, cache- and proxy-visible vocabulary, and let the
`ETag` double as a `304` reconciliation-poll validator. The body field is
still present — collections cannot carry headers per item, and the outbox
persists versions locally.

### 412/409 split

Failed version preconditions return `412`; domain-state conflicts (the
existing already-archived delete, lifecycle errors) remain `409`. The
distinction is contractual: `412` means "refetch and possibly retry";
`409` means "this request cannot be retried as-is."

### Idempotency: vendored idempotency_plug

The `idempotency_plug` library (danschultzer, MIT) is vendored into the
Phoenix app rather than pulled as a dependency: its footprint is small
(~1,200 lines) and upstream is quiet (32 stars, low maintenance activity).
Vendored modules (main plug, `RequestTracker` GenServer, `Store` behaviour,
`EctoStore`) are treated as first-party code — Credo-clean, Reach-clean,
formatted, tested to repo conventions — because vendoring transfers the
maintenance burden. The upstream source commit SHA and MIT attribution are
recorded in each vendored module's moduledoc; upstream is not tracked
(snapshot-and-forget), with the `Store` behaviour as the replacement seam.
The ETS store and the Mix migration generator are dropped; the
request-store table is created by a hand-written migration against
`Dhc.Repo` (Postgres, durable across restarts/nodes) with a 24-hour TTL
(Stripe convention) pruned by the tracker's built-in interval.

Activation is header-gated: a thin gate plug passes requests through
unchanged unless an `Idempotency-Key` header is present, then hands off to
the vendored plug, mounted globally in the authenticated pipelines after
`RequireSession`. Keys are scoped as `{principal_id, key}` so one user's
cached response can never leak to another.

### Idempotency vs version ordering

These two mechanisms solve **different races** and are ordered
independently:

- **Idempotency keys protect retries** — the same logical request reaching
  the server twice. A replayed create returns the *stored* response even if
  the world has moved on since; it does not re-execute, so it never sees a
  version precondition.
- **Version preconditions protect concurrent edits** — two *different*
  logical requests racing on the same entity.

A replayed create therefore returns its original response regardless of
subsequent `lock_version` bumps. Precondition checks (`If-Match`) only
apply to freshly executed writes. This ordering is deliberate: making
replays re-validate would turn a safe retry into a spurious conflict.

### Opt-in, non-breaking

Neither mechanism fires unless the client sends the relevant header
(`If-Match`, `If-None-Match`, or `Idempotency-Key`). Existing clients are
unaffected; responses gain only additive fields (`lockVersion`) and
headers (`ETag`).

## Consequences

- Phase 1.1 (this ADR's implementation) adds the migration, schema fields,
  and optimistic-lock wiring; the HTTP contract (ETag/If-Match/412/304) and
  the vendored plug land in phases 1.2–1.4.
- The OpenAPI spec gains `lockVersion`, conditional headers, and the 412/304
  response shapes, and `@dhc/api-client` is regenerated so the outbox layer
  is compile-checked against the contract (phase 1.5).
- Unsupported conditional headers on versioned resources are rejected with
  `400` (AEP-154: support all preconditions or none, never silently ignore).
- Deletes express conditional semantics via `If-Match` only (no query-param
  variant).
- ETags here are concurrency validators, not HTTP caching; collection
  conditional GETs are out of scope.
- Field-level locking and conflict *resolution* policies stay frontend
  concerns for later PWA phases.

## Considered options

- **Body-only versioning.** Rejected — no standard enforcement mechanism
  and no cheap reconciliation-poll story (see above).
- **409 for stale writes.** Rejected — it would overload 409's existing
  domain-conflict meaning and remove the refetch-vs-give-up distinction
  clients need.
- **`idempotency_plug` as a dependency.** Rejected — quiet upstream plus a
  security-adjacent, transaction-shaped component argues for a vendored
  snapshot we control and audit like first-party code.
- **ETS idempotency store.** Rejected — replay memory must survive deploys,
  restarts, and multi-node operation; upstream's ETS store is dropped.
- **428 Precondition Required / forcing headers.** Rejected — both
  mechanisms stay opt-in indefinitely so the deployed frontend never
  breaks.