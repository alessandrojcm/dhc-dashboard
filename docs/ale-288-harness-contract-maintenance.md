# ALE-288 harness contract 4/5: Maintenance, archive, reminders (FROZEN)

> Status: **FROZEN 2026-09-13 (IMPL 0/5)**. Contract only — no implementation.
> Intended consumer: parallel implementers of the `inventoryMaintenance` /
> `inventoryArchive` E2E scenarios plus the `reminderState` flag on the
> `inventoryLoan` seed (`Dhc.E2EHarness.seed/2` + `E2EScenarios`).
> Post as a Linear comment on ALE-288 when agreed; then implement.
>
> Test-matrix rows this contract serves: **M2** (availability: maintenance
> reason, pending ≠ unavailable), **M4** (archived snapshot: catalog hides,
> own-loan history keeps), **S5** (maintenance/archive interlocks + reminder
> reconciliation smoke). Stories 25–30 (maintenance lifecycle), 52–56
> (archive/restore), 51 (reminders) + 48–50 (notifications/queue).

## Ubiquitous language (from `CONTEXT.md`, not redefined here)

- **Maintenance Period** — an immediately-started interval during which an
  item is unavailable for requests and loans; future maintenance is not
  scheduled in v1. Starting requires a reason, ending may add a note. Start
  and end retain when the change occurred and the operator who recorded it;
  the system does not model who physically did the work. At most one open
  period per item (partial unique index
  `inventory_maintenance_periods_one_open_per_item`).
- **Archived Inventory** — items removed from normal browsing without
  destroying identity or retained history. Operators find them through an
  explicit archive filter; restore requires live dependencies. Members never
  see archived items in the catalog.
- **Loan** — a retained member request. The record survives rejection,
  cancellation, checkout, return, and item archival. Own-loan history keeps
  slug/label snapshots so archival does not rot the record (story 56).
- **Overdue is derived, never stored** — a `checked_out` loan past its
  approved due date in `Europe/Dublin` (`ClubCalendar`) days is overdue.
- **Retention** — loan records and maintenance periods are retained
  permanently. Items with that history are archived, never hard-deleted.
- No legacy vocabulary in this contract: no `out_for_maintenance` boolean,
  no stored availability flag, no quantity, no per-reminder scheduled jobs.

## Target modules (paths only)

- `apps/phoenix/lib/dhc/inventory.ex` (seam — all calls go through here)
- `apps/phoenix/lib/dhc/inventory/operator_item_lifecycle.ex` (move,
  start/end maintenance, archive/restore/delete — presets delegate here,
  this contract does not duplicate the logic)
- `apps/phoenix/lib/dhc/inventory/item_projection.ex` (label + availability:
  recomputed from archive timestamp + open maintenance + approved/
  checked-out loans on every read, never stored)
- `apps/phoenix/lib/dhc/inventory/item_guards.ex` (item locking,
  dependency checks)
- `apps/phoenix/lib/dhc/inventory/member_catalog.ex` (member read model:
  non-archived items only, generic `available` / `on_loan` / `maintenance`
  reason, `:not_found` for archived slugs)
- `apps/phoenix/lib/dhc/inventory/member_loans.ex` (own history with
  slug/label snapshots + approval-gated container path)
- `apps/phoenix/lib/dhc/inventory/loan_reminders.ex` (ledger-is-schedule,
  at most one owed occurrence per pass; ALE-287)
- `apps/phoenix/lib/dhc/inventory/loan_reminder.ex` (ledger schema: key is
  `(loan_id, recipient_principal_id, kind, due_on_revision)`)
- `apps/phoenix/lib/dhc/inventory/workers/loan_reminder_worker.ex`
  (hourly cron driving `LoanReminders.run/0` — named only as the driver,
  never duplicated)
- `apps/phoenix/lib/dhc/notifications.ex` (`create_keyed/3` — named only to
  mark the identity rule, see Non-goals)
- `apps/phoenix/test/support/e2e_harness.ex`
- `apps/web/e2e/e2eApi.ts`
- OpenAPI reference (read-only): `inventoryItems.*` maintenance/archive
  operations and `InventoryOperatorItem` schemas in
  `apps/phoenix/priv/api/openapi.yaml`

## Scenario names

**Two** scenarios plus **one flag** (not a third scenario):

- `inventoryMaintenance` — one scenario with a `preset` enum (`open` |
  `closed`). Covers the maintenance lifecycle on a single item.
- `inventoryArchive` — one scenario, no enum. Covers retiring one item.
- `reminderState` — a flag on the **`inventoryLoan`** seed (handoff 03's
  scenario), not a scenario of its own. It pins what the next
  `LoanReminders.run(today)` owes for that loan, so reminder specs assert
  reconciliation without a separate seeding path.

Structure always comes from `inventoryStructure`, items from
`inventoryItem`, loans from `inventoryLoan`, members from `member` — these
seeds take ids, never names/labels/emails.

## Preset table (preset → resulting state + visible UI effect)

### `inventoryMaintenance`

| `preset` | Resulting period state | Visible UI effect (what Playwright asserts) |
|---|---|---|
| `open` | One open period (`ended_at: null`, `open: true`) | Operator viewer shows `maintenance` (M2); member catalog shows generic `maintenance` reason with no reason text (story 29/45); item is unrequestable (`:item_unavailable`); member request attempts surface the generic refusal. Queue `open_maintenance` owns the row (S5). |
| `closed` | One closed period (`ended_at` set, `open: false`) | Item is available again (assuming no live loan): operator `available`, member catalog `available`, requestable. Period retained in history (`list_operator_item_maintenance_periods/1` newest-first). Item is **not** deletable — the retained period is history (→ archive on cleanup). |

### `inventoryArchive`

| `preset` (none — single path) | Resulting item state | Visible UI effect |
|---|---|---|
| _(archive)_ | `archived_at` set, `archived: true` | Operator viewer shows `archived` (outranks maintenance/loan in projection precedence); member catalog `resolve_catalog_item` answers `:not_found` and list excludes the row with no opt-in filter (M4, story 54); member **own-loan history keeps the slug/label snapshot** readable (story 56, M4). Any open maintenance period is closed atomically with `Archived: <reason>` (or the default archive note). Pending requests on the item are rejected with the archive system note. |

### `reminderState` (flag on `inventoryLoan`, not a preset)

| `reminderState` | Loan setup it requires | What the next `LoanReminders.run(today)` owes |
|---|---|---|
| `preDue` | Live loan (`approved` or `checked_out`) with `approved_due_on = today + 1` and no prior deliveries for the current revision | Exactly one `pre_due` occurrence. Time-windowed: if the day passes undelivered it is never backfilled (the overdue reminder supersedes it). |
| `overdue` | Live loan (`checked_out`) with `approved_due_on = today − N` (`dueOffsetDays`, default `3`), no prior deliveries for the current revision | Exactly one `overdue` occurrence — the first overdue contact, however late discovery is. A month-late loan still gets `overdue` first, never a backlog dump. |
| `weekly` | Live loan (`checked_out`) past due with `overdue` already delivered (seed performs one `run` or inserts the delivered ledger row through the domain path), last delivery ≥ 7 club days ago | Exactly one `overdue_week_<n>` occurrence (`n` = follow-ups sent + 1), paced from the previous **delivery**, not the due date. Body states lateness from the due date itself. |

In all three cases: **one pass → at most one owed occurrence per loan**
(`owed_occurrence/3` returns a single kind or `nil`); a second `run` with
no state change delivers nothing; closed loans (`returned` / `rejected` /
`cancelled`) owe nothing whatever the flag says.

## Attrs

### `inventoryMaintenance` attrs

Top-level attrs object (camelCase, harness convention). `preset` selects
the lifecycle path; every other field feeds that path:

| Field | Type | Required | Notes |
|---|---|---|---|
| `preset` | `"open"` \| `"closed"` | yes | Single scenario, enum-selected path. |
| `itemId` \| `itemSlug` | string (uuid \| `item-NNNNNN`) | yes (one of the two) | `Item.id` / `Item.slug` from `inventoryItem`. Must resolve to an active item at seed time (archived/missing surfaces `:not_found`, never falls back). |
| `reason` | string (1–1000) | yes | Start reason. Maps to `start_operator_item_maintenance %{reason: …}`. Required — an item leaves circulation with context or not at all (`:reason_required`). Empty/whitespace-only surfaces, never defaults. Passed through trimmed, sliced to 1000. |
| `endNote` | string (≤1000) \| null | no (only on `preset: "closed"`) | Closing note for `end_operator_item_maintenance %{endNote: …}`. Omitted/empty → `null`. Non-textual input surfaces. Ignored on `preset: "open"`. |
| `operatorActorId` | string (uuid) | yes | Principal id for `started_by` (and `ended_by` on `closed`). Fail fast when missing; no system actor. SHOULD differ from any borrower holding a loan on the item (attribution hygiene); the seed does not enforce inequality. |

Date/actor wiring per preset (which domain calls the seed makes, in order):

- `open`: `OperatorItemLifecycle.start_operator_item_maintenance(item,
  %{reason}, operator)`. Start timestamp is `now` (immediately-started;
  future maintenance is not scheduled in v1 — there is no start-date
  parameter to abuse).
- `closed`: start as above, then
  `OperatorItemLifecycle.end_operator_item_maintenance(item, %{endNote?},
  operator)`. The seed performs the two calls in that order; it does not
  assert the intermediate open state.

### `inventoryArchive` attrs

| Field | Type | Required | Notes |
|---|---|---|---|
| `itemId` \| `itemSlug` | string (uuid \| `item-NNNNNN`) | yes (one of the two) | `Item.id` / `Item.slug` from `inventoryItem`. Missing resolves to `:not_found`. Already-archived is a **no-op success** (idempotent), not an error. |
| `reason` | string (≤1000) \| null | no (default `null`) | Archive reason. Recorded as the open period's end note as `"Archived: <reason>"`, or the default `"Ended automatically because the item was archived."` when omitted. Empty/whitespace-only → default note path. Unlike maintenance start, archive reason is optional. |
| `operatorActorId` | string (uuid) | yes | Principal id for `archived_by` (and for the atomic period close + pending-request rejections, which attribute to the same actor). Fail fast when missing. |

Domain call: `OperatorItemLifecycle.archive_operator_item(item, %{reason?},
operator)` — one transaction that rejects pending requests, atomically
closes any open period, and stamps `archived_at`. Blocked by an approved
or checked-out loan (`:loan_active`); the seed arranges a blockable-free
item, so the error surfaces only when a spec composes archive over a live
loan deliberately (S5 interlock test).

### `reminderState` flag (on `inventoryLoan` attrs)

| Field | Type | Required | Notes |
|---|---|---|---|
| `reminderState` | `"preDue"` \| `"overdue"` \| `"weekly"` | no (default: none — no reminder setup) | Consumed by the loan seed after it builds the preset path. Pins the due-date geometry + delivery history so the next `LoanReminders.run(today)` owes exactly the named occurrence. Only meaningful on live presets (`approved`, `checkedOut`, `overdue`); on closed presets the flag is accepted but owes nothing (closed loans earn nothing — the spec asserts `due().owed == 0`). |
| (reuses) `dueOn` / `dueOffsetDays` | ISO date / integer > 0 | no | `preDue` forces `approved_due_on = today + 1` (overrides any supplied `dueOn`); `overdue` reuses the preset's `dueOffsetDays` backdate (default `3`); `weekly` = `overdue` geometry plus a delivered `overdue` ledger row for the current revision (via one domain `run`, never a raw insert), with the delivery day ≥ 7 club days before `today` so the follow-up is owed. |

The flag performs **no notification writes itself** — notifications are
produced only by `LoanReminders.run/1` down the claim → `create_keyed/3` →
stamp path. The seed sets up *owedness*; the spec runs the pass live and
asserts delivery + idempotency.

## Result

Viewer-neutral ids (camelCase, **not** rendered JSON blobs — the harness
returns plain maps, never `*JSON.render/2` output).

### `inventoryMaintenance` result

| Field | Type | Notes |
|---|---|---|
| `periodId` | string (uuid) | `MaintenancePeriod.id`. The FK reminder/queue specs use. |
| `itemId` | string (uuid) | Echo of the maintained item. |
| `slug` | string (`item-NNNNNN`) | Item slug echo (resolution key alongside `itemId`). |
| `open` | boolean | `true` on `preset: "open"` (`ended_at: null`); `false` on `preset: "closed"`. The single flag specs branch on. |
| `reason` | string | Echo of the trimmed start reason. Lets M2 assert the operator viewer carries the reason while the member catalog does not (see Member-projection rule). |
| `startedBy` | string (uuid) | Echo of `operatorActorId` (start attribution). |
| `endedBy` | string (uuid) \| null | Closer attribution; `null` on `open`. |

### `inventoryArchive` result

| Field | Type | Notes |
|---|---|---|
| `itemId` | string (uuid) | Echo of the archived item. |
| `slug` | string (`item-NNNNNN`) | Slug echo — still resolvable operator-side, absent member-side. |
| `archived` | boolean | Always `true` (idempotent no-op still returns `true`). The single flag specs branch on. |
| `archivedBy` | string (uuid) | Echo of `operatorActorId`. |
| `catalogHidden` | boolean | Proof the member projection hides it: `true` iff `MemberCatalog.resolve_catalog_item(slug)` answers `:not_found`. Always `true` on success — returned so specs assert the proof without a second read. |
| `historyKept` | boolean | Proof own-loan history survives: `true` iff every loan on the item remains readable through `MemberLoans.get_own_loan/2` with its slug/label snapshot intact. Vacuously `true` when the item has no loans (the archived-with-history example shows the non-vacuous case). |

### `reminderState` result (merged into the `inventoryLoan` result)

| Field | Type | Notes |
|---|---|---|
| `owedKind` | `"pre_due"` \| `"overdue"` \| `"overdue_week_<n>"` \| null | The single occurrence `LoanReminders.owed_occurrence/3` returns for this loan at seed time (`null` on closed loans or when no flag was given). Echo so specs assert `run(today)` delivers exactly this kind without recomputing the schedule. |
| `notificationKey` | string \| null | The keyed-notification identity for that occurrence: `"inventory:loan:<loanId>:reminder:<kind>:r<revision>"` where `revision = Date.to_gregorian_days(approved_due_on)`. `null` when `owedKind` is `null`. Specs assert `(principal_id, notification_key)` uniqueness on this value (see Keyed-notification identity). |

## Rules to pin

Seed-visible consequences of domain rules (the seed assumes valid input;
it does not exercise error paths beyond surfacing caller mistakes):

- **Availability is an `EXISTS`-projection, never a stored flag.**
  `ItemProjection.availability/1` recomputes from the archive timestamp,
  the open-maintenance `EXISTS`, and the approved/checked-out-loan
  `EXISTS` on every read (precedence `:archived` → `:maintenance` →
  `:on_loan` → `:available`); the member availability filter
  (`MemberCatalog.filter_availability/2`) constrains on the **same**
  `EXISTS` facts, not a new column. Pending requests are deliberately not
  an input (M2: competing requests coexist on an available item; S5: the
  queue's `open_maintenance` bucket and the catalog reason cannot
  disagree because they read the same rows). The seed asserts nothing
  stored — specs assert the projection through the operator viewer and
  the catalog read.
- **At most one open period; start rejects pending, blocked by live
  loans.** `start_operator_item_maintenance/3` refuses
  `:maintenance_open` when a period is already open, rejects every
  `requested` row on the item in the same transaction with the system
  note `"Rejected automatically: the item went into maintenance."`, and
  is blocked by an approved/checked-out loan (`:loan_active`). The
  `open` preset performs this closure silently when no competitors
  exist; a spec needing the visible rejection seeds a `requested` loan
  first (S5 interlock test) and asserts the flip live.
- **Archive ends the open period atomically, rejects pending, blocked by
  live loans.** `archive_operator_item/3` closes any open period with
  `Archived: <reason>` (or the default note), rejects pending requests
  with `"Rejected automatically: the item was archived."`, and surfaces
  `:loan_active` while an approved/checked-out loan holds the item.
  Archiving an already-archived item is a no-op success. Restore gating
  (live category, whole container chain active, retained values still
  valid) is **out of scope** — documented, not seeded (see Out of scope).
- **Member-projection rule: only the generic `maintenance` reason leaks;
  operator notes never leak (stories 29/45).** The member catalog row
  carries `availability: %{available?: false, reason: :maintenance}` and
  nothing else — no start reason, no end note, no `started_by`, no
  borrower, no dates. The operator projection carries the full period
  (`start_reason`, notes, attribution). The `inventoryMaintenance` result
  echoes `reason` precisely so M2 can assert it is present operator-side
  and absent member-side in one fixture. Archived items have no
  member-safe explanation of their own and map to the same generic
  `maintenance` reason if ever projected; in practice they are filtered
  out (`:not_found`, never `"archived"`).
- **One pass → at most one owed occurrence per loan.**
  `LoanReminders.owed_occurrence/3` maps (due date, today, delivered
  history) onto a single kind or `nil`: `pre_due` only on the
  day-before, never backfilled; `overdue` as the first overdue contact
  however late discovery is; `overdue_week_<n>` paced ≥ 7 club days from
  the previous *delivery* (never calendar-derived, so a month-late loan
  repairs without a backlog dump). `due/1` and `run/1` take an explicit
  `today` so specs advance *time* without rewriting a due date (which
  would be a date *edit*).
- **Keyed-notification identity: the key names the logical event.**
  Delivery is claim → notify → stamp with the ledger key and the
  notification key as the **same identity**
  (`inventory:loan:<id>:reminder:<kind>:r<revision>`); `create_keyed/3`
  scopes uniqueness to `(principal_id, notification_key)`, so one event
  notifies the borrower from one key and a retry resolves to
  `:already_created` (broadcast only on `:created`, never updating the
  existing row). The ledger insert `ON CONFLICT DO NOTHING` serializes
  concurrent passes without locks. A crash between claim and stamp
  leaves an unstamped row the next pass repairs down the same path —
  normal delivery and reconciliation are the same code path (S5 smoke).
- **Closed loans earn nothing; due-edit reschedules for free.** Only
  `approved`/`checked_out` loans are considered, with status re-read
  under the claim (a return committing between read and delivery releases
  the claim rather than notifying). `due_on_revision` is **derived**
  (`Date.to_gregorian_days(approved_due_on)`), never incremented — so a
  due-date edit invalidates every old key and earns the new date its own
  occurrences with no write on the transition path, which is why
  `OperatorLoans` stays reminder-free. Restating the same date changes
  no key.
- **Container path stays an approval entitlement through all of this.**
  Maintenance/archive never rewrite a loan's
  `approved_container_path_snapshot`; a later container move does not
  rewrite where an approved borrower was told to go. The harness keeps
  returning the member-visible rule (`null` before approval) so
  maintenance specs cannot assert a leak.

## Out of scope for the seed (assumes valid input)

- **Archive-restore gating as behavior** (live category, whole container
  chain active, retained values still valid against current definitions).
  Restore is a domain command (`restore_operator_item/2`) exercised by
  operator API tests, not a preset: the permitted seed-adjacent assertion
  is `delete_fixture("inventoryArchive", …)` → restore (see Cleanup),
  which surfaces `:archived_category` / `:archived_container` /
  `:invalid_values` rather than satisfying the gates. No preset archives
  *and* restores in one seed.
- **Container moves under maintenance** (allowed) vs. under live loan
  (blocked `:loan_active`), and **movement as a general edit** — the move
  command (`move_operator_item/3`) belongs to the item-lifecycle operator
  API tests, not these fixtures. Seeds place items once via `containerId`.
- **Reclassification, required-gates, retire flows** — owned by the
  structure/item contracts; never seeded here.
- **Transition notifications** (approval/rejection/cancel/due-change
  bodies, silent checkout/return/auto-rejection) — handoff 03's boundary
  states this seed exercises transitions without reading the
  notification table; **reminder** notifications are the only ones this
  contract asserts, and only through `owedKind`/`notificationKey` +
  `LoanReminders.run/1`.
- **Operator overdue notification** (story 50, queue exposure) — belongs
  to the queue/exposure ticket; the ledger is already keyed by
  `recipient_principal_id` for a second recipient per occurrence, so no
  reshape is needed when it lands.
- **The hourly worker as a scheduler** (`LoanReminderWorker` cron
  shape, Oban config) — the seed calls `LoanReminders.run(today)`
  directly; the worker is the driver, never the schedule.

## Validation: surface vs. accept

Seeds fail fast on caller mistakes; they never paper over conflicts with
fallbacks. Concretely, the implementer maps:

**Surface (raise / return harness 422-or-409 — never silent):**

- Missing/unknown `itemId`/`itemSlug` → `:not_found` (archived slugs
  answer absent member-side, never `"archived"`).
- `inventoryMaintenance` without `reason`, with empty/whitespace-only
  `reason`, or with non-textual `reason` → `:reason_required`.
- `inventoryMaintenance` on an archived item → `:archived` (archive
  closed the period atomically; there is nothing to start or end).
- `inventoryMaintenance` `open` while a period is open →
  `:maintenance_open` (409); `closed` with no open period →
  `:no_open_maintenance` (422). The seed arranges the valid state, so
  these surface only on illegal compositions (e.g. two `open` seeds on
  one item).
- `inventoryMaintenance` or `inventoryArchive` blocked by an approved /
  checked-out loan → `:loan_active` (409). Fresh seeds never have loans;
  the error is reachable only when composed over a live-loan fixture —
  which is the S5 interlock assertion, not a seed bug.
- Missing `operatorActorId` on any preset → harness arity error, no
  system actor.
- Over-length `reason`/`endNote` (>1000) → sliced to 1000 per the domain
  trim-then-slice (not an error); non-textual `endNote` → `:invalid_text`.
- `reminderState` on a `competingPair` loan or with an unknown flag
  value → harness arity error (reminder geometry needs exactly one live
  loan with one due date).
- Second pending request by the same member on an item under maintenance
  → `:item_unavailable` (not `:duplicate_request` — availability is
  checked first).

**Silently accept / normalize (documented defaults, not errors):**

- Omitted `endNote` / empty / whitespace-only → `null`.
- Omitted `reason` on `inventoryArchive` → `null` (default archive end
  note path); empty/whitespace-only → same.
- `inventoryArchive` on an already-archived item → no-op success
  (`archived: true`, same `catalogHidden`/`historyKept` proofs).
- `reminderState` omitted → no reminder setup (`owedKind: null`,
  `notificationKey: null`); the loan preset behaves exactly as handoff
  03 specifies.
- `reminderState` on a closed loan preset → accepted, `owedKind: null`
  (closed loans earn nothing — the spec asserts `due().owed == 0`,
  not a seed error).
- Whitespace-padded `reason`/`endNote` → trimmed then sliced; label
  casing never pre-normalized.
- `preDue` overriding a supplied `dueOn` → the flag wins (reminder
  geometry is the point of the flag); the result echoes the effective
  `dueOn` via the loan result's `dueOn` field.

## Cleanup semantics (`delete_fixture` / `update_fixture`)

Retention (from `CONTEXT.md`): maintenance periods and loan records are
retained permanently. Items with that history are archived, never
hard-deleted. There is no domain delete for periods, loans, or archived
items — E2E teardown breaks this rule deliberately and narrowly:

- `delete_fixture("inventoryMaintenance", periodId)`:
  - Open period → end it via `end_operator_item_maintenance/3` with the
    canned note `"E2E teardown: closing open maintenance."` Attributed
    to the seed's `operatorActorId` where available, else the caller.
    Asserts `open: false`, not row absence.
  - Closed period → no-op success (retained history; the item stays
    non-deletable → archived on item cleanup). The helper never deletes
    period rows — deleting a retained period would resurrect a
    `deletable: true` the retention rule forbids.
  - Unknown `periodId` → `{:error, :not_found}`.
- `delete_fixture("inventoryArchive", itemId)`:
  - Archived → restore via `restore_operator_item/2` (the only legal
    "un-archive"). Surfaces `:archived_category` / `:archived_container`
    / `:invalid_values` when dependencies drifted — the test must
    reactivate dependencies first or assert the gate deliberately.
    Asserts `archived_at` cleared, not row absence.
  - Active → no-op success. Never hard-deletes: a with-history item
    stays under the item contract's archive path; a history-free item
    stays under its hard-delete path. This fixture never deletes items.
- `delete_fixture("inventoryLoan", loanId)` with a `reminderState`: unchanged
  from handoff 03 (test-only hard-delete of the loan row, entries
  individually for pairs). Reminder ledger rows for the loan are deleted
  alongside (claimed-but-undelivered first, then delivered) — otherwise a
  re-seeded loan with the same id geometry would inherit another loan's
  delivered history. Notification rows are **left untouched** (they are
  per-user facts another spec may still assert); keyed idempotency makes
  leftovers harmless to a fresh loan id.
- `update_fixture`:
  - **Not supported** for any of `inventoryMaintenance`,
    `inventoryArchive`, or reminder state. Periods have no generic patch
    (open → the `closed` preset's end command; closed → immutable);
    archive has no patch (restore is cleanup, not an edit); reminder
    geometry changes by re-seeding the loan flag (which re-derives the
    revision) or driving the operator date-edit route live (which
    reschedules for free). `E2EUpdatableFixture` gains no member from
    this contract.

Which seed is deletable (reminder for the item contract):

| Seed | Item `deletable` after | Cleanup |
|---|---|---|
| `inventoryMaintenance` `open` or `closed` | `false` | item cleanup archives (period is retained history); period cleanup ends-or-no-ops |
| `inventoryArchive` | `false` | archive cleanup restores; item cleanup archives (no-op) |
| `inventoryLoan` + any `reminderState` (live loan) | `false` (loan history) | loan cleanup hard-deletes loan + ledger rows; item cleanup archives |
| `inventoryLoan` + `reminderState` on closed loan | `false` | same (closed record is still history) |

## TS side (proposed — implement when this contract is accepted)

```ts
type InventoryMaintenanceSeed = {
  attrs: {
    preset: "open" | "closed";
    itemId?: string;
    itemSlug?: string;
    reason: string;
    endNote?: string | null;
    operatorActorId: string;
  };
  result: {
    periodId: string;
    itemId: string;
    slug: string;
    open: boolean;
    reason: string;
    startedBy: string;
    endedBy: string | null;
  };
};

type InventoryArchiveSeed = {
  attrs: {
    itemId?: string;
    itemSlug?: string;
    reason?: string | null;
    operatorActorId: string;
  };
  result: {
    itemId: string;
    slug: string;
    archived: boolean;
    archivedBy: string;
    catalogHidden: boolean;
    historyKept: boolean;
  };
};

type ReminderState = "preDue" | "overdue" | "weekly";

// merged into the handoff-03 loan attrs/result (flag + two echoed fields):
type InventoryLoanReminderExtension = {
  attrs: {
    reminderState?: ReminderState;
  };
  result: {
    owedKind: "pre_due" | "overdue" | `overdue_week_${number}` | null;
    notificationKey: string | null;
  };
};

// in E2EScenarios:
type E2EScenarios = {
  // …existing…
  inventoryMaintenance: InventoryMaintenanceSeed;
  inventoryArchive: InventoryArchiveSeed;
  // inventoryLoan gains the optional reminderState flag + owedKind /
  // notificationKey on its result; no new scenario name.
};
```

`E2EFixtureType` gains `"inventoryMaintenance"` and `"inventoryArchive"`
automatically via `Exclude<E2EScenarioName, …>`; `E2EUpdatableFixture`
explicitly **excludes** both (seed/delete-only, like loans).
`setupFunctions.ts` gets `createInventoryMaintenance(preset, …)` and
`createInventoryArchive(…)` helpers in the implementing ticket (not this
contract), plus a `withReminderState(loanAttrs, state)` wrapper on the
existing `createInventoryLoan()` — no second loan helper.

## Example payloads

Assumes an `inventoryStructure` seed returned a container path
(`Cage › Rack 2`), an `inventoryItem` seed returned `itemId`/`slug`, a
`member` seed returned `memberId` (borrower) and an operator `memberId`
(actor), and dates are club-calendar ISO dates. UUIDs below are
illustrative.

### 1. `open` maintenance — item leaves circulation with context (M2 + S5)

Attrs:

```json
{
  "preset": "open",
  "itemId": "55555555-5555-4555-8555-555555555555",
  "reason": "Cracked guard — quarantining until the armoury checks it",
  "operatorActorId": "22222222-2222-4222-8222-222222222222"
}
```

Result:

```json
{
  "periodId": "p1p1p1p1-p1p1-4p1p-p1p1-p1p1p1p1p1p1",
  "itemId": "55555555-5555-4555-8555-555555555555",
  "slug": "item-000124",
  "open": true,
  "reason": "Cracked guard — quarantining until the armoury checks it",
  "startedBy": "22222222-2222-4222-8222-222222222222",
  "endedBy": null
}
```

Operator viewer: `available?: false, status: :maintenance` **with** the
reason. Member catalog: `available?: false, reason: :maintenance` with
**no** reason text (story 29/45 — the `reason` echo above is what lets
the spec assert both sides from one fixture). Queue: the item sits in
`open_maintenance`. A member request for the item surfaces generic
`:item_unavailable`. Cleanup: `delete_fixture` ends the period; the item
stays `deletable: false`.

### 2. Archived with history — catalog hides, own-loan history keeps (M4)

Setup: an `inventoryLoan` seed already created a `returned` loan on the
item (borrower `11111111-1111-4111-8111-111111111111`), so retained
history exists.

Attrs:

```json
{
  "itemId": "55555555-5555-4555-8555-555555555555",
  "reason": "Retired — guard crack beyond repair",
  "operatorActorId": "22222222-2222-4222-8222-222222222222"
}
```

Result:

```json
{
  "itemId": "55555555-5555-4555-8555-555555555555",
  "slug": "item-000124",
  "archived": true,
  "archivedBy": "22222222-2222-4222-8222-222222222222",
  "catalogHidden": true,
  "historyKept": true
}
```

`catalogHidden: true` means `MemberCatalog.resolve_catalog_item(slug)`
answers `:not_found` and the list read excludes the row (story 54).
`historyKept: true` means `MemberLoans.get_own_loan(loanId, borrower)`
still returns the `returned` record with its `item_slug` /
`item_label` snapshot intact (story 56). If the item had an open period,
archive closed it atomically with
`"Archived: Retired — guard crack beyond repair"`. Restore gating (live
category + container chain + valid retained values) is a documented
out-of-scope — asserted only via `delete_fixture` surfacing the gate,
never via a preset. Cleanup: `delete_fixture` restores; the item is
never hard-deleted.

### 3. Overdue needing reminder — one pass owes exactly one occurrence (S5 + story 51)

Attrs (`inventoryLoan` seed with the `reminderState` flag; borrower and
operator ids as in handoff 03):

```json
{
  "preset": "checkedOut",
  "itemId": "55555555-5555-4555-8555-555555555555",
  "borrowerMemberId": "11111111-1111-4111-8111-111111111111",
  "startsOn": "2026-09-07",
  "dueOn": "2026-09-11",
  "operatorActorId": "22222222-2222-4222-8222-222222222222",
  "reminderState": "overdue"
}
```

(`dueOn` backdated `dueOffsetDays: 3` behind club `today = 2026-09-14`
through the preset's harness-only time-travel write; no prior deliveries
for the current revision.)

Result (loan fields per handoff 03, plus the reminder extension):

```json
{
  "loanId": "e5e5e5e5-e5e5-4e5e-e5e5-e5e5e5e5e5e5",
  "status": "checked_out",
  "overdue": true,
  "itemId": "55555555-5555-4555-8555-555555555555",
  "slug": "item-000124",
  "borrowerMemberId": "11111111-1111-4111-8111-111111111111",
  "startsOn": "2026-09-07",
  "dueOn": "2026-09-11",
  "containerPath": "Cage › Rack 2",
  "decidedBy": "22222222-2222-4222-8222-222222222222",
  "owedKind": "overdue",
  "notificationKey": "inventory:loan:e5e5e5e5-e5e5-4e5e-e5e5-e5e5e5e5e5e5:reminder:overdue:r739738"
}
```

The S5/story-51 smoke test from here: `run(today)` delivers one
notification to the borrower under `notificationKey`; a second `run`
delivers nothing; `due()` reports `{owed: 0, pending: 0}`; re-running
after a simulated crash resolves `:already_created` on the same
`(principal_id, notification_key)` (key = logical event, never the
recipient). A due-date edit (`edit_loan_dates` moving `dueOn` forward)
derives a new `due_on_revision`, so the old key is dead and the new date
earns its own `pre_due`/`overdue` occurrences with no write on the
transition path. A `returned` loan with the same flag returns
`owedKind: null` — closed loans earn nothing.
