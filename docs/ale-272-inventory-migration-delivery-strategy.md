# ALE-272 — Inventory migration and delivery strategy

**Status:** implementation-ready delivery decision
**Scope:** replace the migrated Inventory slice with the agreed Inventory and
Loan model. This plan does not authorize a production migration.

## Decision

Use an **expand → target-code → cutover → contract** delivery sequence. Retain
Phoenix ownership, generated OpenAPI/client ownership, the `Dhc.Inventory`
capability seam, direct Item-to-Category/Container links, and the equal
Inventory Operator role set. Replace quantity records, free-form JSON
properties, boolean Maintenance, generic-history writes, destructive lifecycle,
and member-visible management pages.

The legacy DTO is not a safe compatibility adapter: `quantity`, `photoUrl`,
JSON attributes, `outForMaintenance`, member visibility, and delete/history
semantics differ materially from the target. Run target and legacy surfaces
side-by-side only long enough to move callers; never translate target commands
back into legacy semantics.

This implements the settled Inventory terms in `CONTEXT.md`, ALE-273, ALE-275,
ALE-278, ALE-279, the mobile-workflow prototype, and the implementation audit.
ALE-279 supersedes ALE-275's conflicting statement on due-date edits:
operators may update an approved or checked-out `dueOn`; the member is notified
and reminders are rescheduled.

## Capability seams

`Dhc.Inventory` remains the one public Phoenix module used by controllers and
workers. It is the deep module: callers receive catalog projections and domain
commands; it hides locks, storage shape, availability calculation, and
notification scheduling.

| Internal target module | Interface responsibility | Hidden implementation |
| --- | --- | --- |
| `Catalog` | Member-safe Item browse, facets, detail, slug lookup | Derived label, availability, archive filters, privacy projection |
| `Structure` | Operator Category, Definition/Option, and Container administration | In-use property evolution, case uniqueness, cycle/dependency guards |
| `Items` | Operator Item create/edit/archive/restore/delete/move | Slug minting, typed values, lifecycle interlocks |
| `Maintenance` | Start/end and operator inspection of retained periods | Open-period uniqueness and availability serialization |
| `Loans` | Member self-service and operator queue/lifecycle commands | Item lock, allocation, competing-request rejection, viewer projections |
| `Reminders` | Scheduled reminder selection/reconciliation | Dublin-date scheduling and durable deduplication |

All availability-changing commands take the same Item row inside one outer
`Repo.transaction/1` using `SELECT ... FOR UPDATE`: request, approval,
rejection/cancellation, checkout/return, due-date edit, start/end Maintenance,
archive/restore/delete, and move where an active Loan can block it. Database
constraints are the backstop; a unique conflict becomes a domain `409`, never a
500.

Catalog and Loan reads are viewer-shaped interfaces. Ordinary Member Item
responses never disclose a Container, borrower, another Member's Loan, or
operator-only Maintenance facts. The Container path appears only in the
entitled request/approved-Loan projection. Inventory Operators receive the
operational projection. This makes privacy server-enforced rather than a
Svelte conditional.

Notifications keep their existing narrow seam: `Dhc.Notifications.create/2`
remains the only supported Notification creation API and continues to own its
transaction plus after-commit best-effort broadcast. A Loan command first
commits its Inventory transaction; only after that return may its caller invoke
`Notifications.create/2` for the decided event. It must never expose a raw or
transaction-composable Notification insert, invoke `create/2` inside the
Inventory transaction, broadcast before commit, or use Oban/outbox as a second
delivery path. The transition is durable even if the separate notification
write fails; log and alert that failure for operator repair. Reminder
deduplication is a durable Loan ledger, not an inference from unread
notifications.

The command interlock matrix is explicit: a requested or approved Loan may be
cancelled; an approved Loan may be checked out or cancelled; only a checked-out
Loan may be returned. Starting Maintenance atomically rejects requested Loans
and is rejected while an Item has an approved or checked-out Loan. An Item may
move while it has an open Maintenance Period, but never while it is approved or
checked out. Archiving rejects requested Loans, is rejected for an approved or
checked-out Loan, and atomically ends an open Maintenance Period with the
archive reason. Hard deletion requires no retained Loan, Maintenance, or legacy
history; an Item with any such record is archive-only. Restoration rechecks
active Category/Container dependencies and required property values.

## Retain, correct, replace, build

| Area | Decision | Implementation action |
| --- | --- | --- |
| Phoenix and generated-client ownership | **Retain** | Keep every Inventory read/write behind Phoenix and `@dhc/api-client`; no browser table access. |
| `Dhc.Inventory` seam | **Retain and reshape** | Keep one public capability module, but expose caller intent rather than table CRUD. |
| Direct Category/Container links | **Retain and strengthen** | Keep Item home Category/Container FKs; add archive/dependency and typed-value invariants. |
| Role gate | **Retain** | Keep quartermaster/president/admin equal; split member catalog/own-Loan routes from operator routes. |
| Container cycle intent and move command | **Retain and correct** | Preserve friendly application validation/command shape; add DB protection and Loan interlock. |
| Existing Phoenix tests | **Retain temporarily** | Treat as characterization until each touched legacy behavior has a green target replacement test. |
| Quantity, photo, JSON definition/value columns | **Replace** | Use physical Item slug and normalized Definition/Option/Value tables; drop legacy fields only in contract. |
| Maintenance boolean and generic history writes | **Replace** | Use retained Maintenance Periods and Loans; preserve old history read-only as legacy evidence. |
| Cascade deletion | **Correct** | Replace Item-history and Container-parent cascades with restrictive FKs plus archive/restore rules. |
| Existing Svelte management pages/skipped E2E | **Replace** | Build member catalog/request/history and operator management/queue/actions from target generated types. |
| Physical labels and QR scan | **Build** | Label printing is in the first target release once slugs exist. QR camera scan is an optional convenience adapter; it chooses the normal slug route and never authorizes or acts. |

## Additive database target

All new person FKs point at Phoenix `principals.id`, not `auth.users`. The
preflight checks existing Inventory actor links first. Equivalent names are
allowed only if they preserve these invariants.

### Item and lifecycle

1. Add `inventory_items.slug text`: nullable only while backfilling, then
   `NOT NULL` and uniquely indexed. Generate server-side from a database
   sequence as `item-` plus a zero-padded monotonically increasing number.
   It is immutable, human-readable, collision-free, and not a credential.
2. Add `inventory_items.archived_at` and optionally `archived_by_principal_id`.
   Do not store a label or availability flag; both are projections.
3. Add `equipment_categories.archived_at` and `containers.archived_at`.
   A Category cannot be hard-deleted while any active or archived Item refers
   to it, and may be archived only when no active Item depends on it. Its
   restoration is rejected until all required active Definition/option
   dependencies are restorable. Definition/option hard deletion is likewise
   blocked by any active or archived value reference.
4. Change the Container parent FK to `ON DELETE RESTRICT`; add a root-safe,
   case-insensitive sibling-name unique index and a deferred constraint trigger
   that rejects self/descendant parenting. Keep app-level cycle validation for
   useful errors.
5. A Container archive command is rejected while any direct or descendant
   Container or Item is active. Operators must first move, archive, or
   hard-delete each direct/descendant dependent explicitly; no subtree action
   is recursive. A Container restore is rejected unless its parent chain is
   active. Creating, moving, or restoring an active Item into an archived
   Container is rejected. These command rules are backed by dependency queries
   under the relevant Container/Item locks; the restrictive FKs prevent a
   destructive bypass.
6. Change `inventory_history.item_id` from cascade to `ON DELETE RESTRICT`.
   Preserve existing rows as immutable legacy evidence but never write another
   generic creation/update/movement/maintenance event.

### Typed properties

1. Add `inventory_property_definitions` with stable UUID, `category_id`,
   mutable `label`, immutable-in-use `value_type` (`text`, `decimal`,
   `boolean`, `single_select`), `required`, nullable `identifying_position`,
   and nullable `retired_at`.
2. Enforce case-insensitive Definition-label uniqueness per Category and a
   unique non-null identifying position per Category.
3. Add `inventory_property_options` with stable UUID, Definition FK, mutable
   label, position, and nullable `retired_at`; enforce case-insensitive option
   uniqueness per Definition.
4. Add `inventory_item_property_values`, keyed by `(item_id,
   property_definition_id)`, with exactly one of `text_value`, `decimal_value`,
   `boolean_value`, or `option_id`. Empty text has no row; `false` is present.
   Checks/triggers enforce exactly-one, matching definition type, definition
   Category matching the Item Category, and Option membership.
5. Retired definitions/options remain available for archived Item values. A
   Category change must atomically map/clear old values and supply all required
   values for the new Category.

### Retained Maintenance and Loans

1. Add `inventory_maintenance_periods`: `item_id`, `started_at`,
   `started_by_principal_id`, required `start_reason`, nullable `ended_at`,
   `ended_by_principal_id`, and nullable `end_note`. Use restrictive FKs and a
   partial unique index on `item_id WHERE ended_at IS NULL`.
2. Add `inventory_loans`: Item and borrower Principal FKs, status
   (`requested`, `approved`, `rejected`, `cancelled`, `checked_out`,
   `returned`), requested/approved date fields, simple notes, and the required
   decision/checkout/return timestamps and recording actor IDs. All FKs are
   restrictive. At request creation, capture immutable borrower-history display
   facts—at least Item slug and derived label—in `item_slug_snapshot` and
   `item_label_snapshot`; Item archival, later Category/property edits, or a
   future hard-to-render reference cannot corrupt historical Loan display. At
   approval, capture the entitled home Container path in
   `approved_container_path_snapshot` for the approval notification and Loan
   detail. These snapshots are presentation evidence, not a second Item
   identity, availability source, or custody model. No Loan backfill is needed
   because no legacy Loans exist.
3. Enforce requested and approved date ordering; after checkout, `dueOn` cannot
   precede actual checkout. Ecto validations produce useful errors; checks and
   triggers protect direct writes.
4. Add partial unique indexes for one pending request per Item/borrower and at
   most one approved/checked-out Loan per Item. Index status/due-date queue and
   reminder queries.
5. Add `inventory_loan_reminders`, keyed by `(loan_id, kind,
   due_on_revision)` or an equivalent immutable schedule key. A due-date change
   advances the revision/cancels obsolete schedules, so retry cannot emit the
   old reminder.

Use `NOT VALID` constraints then validate after backfill where appropriate.
Keep additive migration steps isolated from any concurrent-index operation
required for a large production table.

Every new Phoenix-owned table uses the production timestamp convention:
`timestamps(type: :timestamptz, inserted_at: :created_at)` plus `updated_at`
where it is a mutable current fact. The matching Ecto schema declares
`created_at` (not `inserted_at`), and bulk/import writes set explicit
`created_at` values. Retained period/Loan transition timestamps remain their
separate domain facts and never substitute for record creation time.

## Production data: profile, reconciliation, backfill

Before target backfill, ship `mix dhc.inventory.profile`: a read-only task that
writes a versioned aggregate JSON/Markdown profile. First run it against a
restored production backup, then production with a read-only credential. Record
only aggregate counts/anomaly classes, backup ID, revision, digest, and
timestamp—never raw member data, Item notes, or individual IDs in the
repository. IDs are queried transiently for counts and reconciliation; any
row-level reviewed mapping remains an access-restricted operator artifact, not
a versioned repository report.

The profile must cover:

- aggregate counts and oldest/newest date ranges for Categories, Containers,
  Items, and history; null/orphan actor and reference counts. The task may use
  individual IDs transiently to derive those aggregates but must not emit them
  in the versioned profile;
- every `quantity > 1` Item, photo presence/storage ownership, JSON keys/types,
  absent/unrecognized values, duplicate-looking definitions/options, and use of
  `attribute_schema`;
- definition/option case collisions; Container sibling collisions, missing
  parents, cycles, and potential old cascade subtrees;
- maintenance-flagged Items, history action counts/missing actors/container
  links; and
- active endpoint writers, integrations, and deployed Svelte releases using
  legacy Inventory APIs.

Two paths follow the profile:

- **Routine:** no ambiguous mapping, tree anomaly, collision, unowned photo, or
  quantity record requiring operator judgment. Rehearse a deterministic
  backfill on restored production data before running it.
- **Reconciliation required:** produce an operator-reviewed mapping file using
  stable legacy IDs and dispositions (`map`, `clear`, `retire`, `archive`, or
  `exclude`). The backfill validates complete, fresh one-to-one mappings and
  aborts on anything unmapped. It never guesses from similar labels.

Backfill rules:

1. Mint a slug per physical unit. `quantity = 1` retains its Item UUID. A
   `quantity > 1` row becomes that many Items: the old UUID is one unit and new
   UUIDs are the remainder. Copy Category, Container, approved typed values,
   and current notes; record old-ID/ordinal in import provenance, not notes.
2. Translate only exact valid legacy definitions/options/JSON values. Missing or
   empty text is absent; do not fabricate values or defaults.
3. Do not invent Maintenance history from `out_for_maintenance`. A flagged Item
   receives an operator-reviewed imported open period that explicitly says its
   historical start/actor are unknown, or a temporary import hold until an
   operator reconciles it.
4. Preserve `inventory_history` in place when FKs validate. Do not turn it into
   Maintenance/Loan facts. No Loan backfill exists because Loans were absent.
5. Retain `photo_url` until ownership/disposition is proven. Dropping the DB
   column never deletes storage objects as a side effect.

Backfills are repeat-safe through unique provenance and deterministic keys;
they validate expected source/target counts and fail closed on drift. Rehearsal
migrates a restored backup to the exact target version; never rerun the
baseline Inventory migration in production.

Before the final production profile/mapping snapshot and backfill, enter the
announced Inventory write freeze and verify zero legacy mutations. The profile
digest is therefore the exact source set for the backfill rather than an
earlier moving target. Keep the freeze through backfill aggregate validation,
legacy-write disablement, target release deployment, and target smoke checks.
This intentionally moves the final production backfill into the controlled
cutover window; restored-backup rehearsal establishes its duration first.

## OpenAPI, generated client, and compatibility

`apps/phoenix/priv/api/openapi.yaml` remains authoritative. Correct its global
and Inventory auth text to Phoenix cookie sessions and declare `cookieSession`
on target operations. Remove stale Inventory JWT/`auth.users` wording.

Keep **one `Inventory` OpenAPI tag and one `/api/inventory` root**. Add
viewer-shaped target schemas and operation names under that one domain instead
of mutating legacy Item schemas in place:

| Contract | Required target operations |
| --- | --- |
| Catalog operations | Member-safe Item list/filter/detail, immutable slug lookup/deep link, derived label, facets, generic availability reason, no borrower/operator leakage. |
| Management operations | Operator Category/Definition/Option, Container, Item management; typed values; explicit archive/restore/delete eligibility; label-print payload. |
| Maintenance operations | Operator start/end/list retained Maintenance Periods. |
| Loan operations | Member request/list/detail/cancel; operator list/detail/queue/counts and approve/reject/cancel/checkout/return/due-date commands. Explicit `409` conflict and `422` invalid transition errors. |

Use command-specific request schemas. A generic Item PATCH must never mutate
Maintenance, location, archive state, or Loan state. Queries are projections;
commands return the new projection after their atomic transaction.

All list endpoints use `Dhc.CursorPagination`: opaque cursors bind limit, sort,
direction, and every filter; queries have stable ordering with an `id`
tie-break; mismatched/stale cursors return `400`; and an exposed `totalCount`
uses exact `COUNT(*)`. Every target and compatibility success is `{ data: ... }`
and every error is `{ errors: { detail: string } }`; DTO fields are camelCase
and omit internal FKs, provenance, storage, actor, and privacy-sensitive values
unless the viewer-specific operation requires them.

Loan command schemas enforce the settled lifecycle policy directly: only an
active Member requests their own Loan; request `startsOn` and `dueOn` are
`Europe/Dublin` calendar dates, each today or later, with `dueOn >= startsOn`.
Checkout is only from an approved Loan on/after `startsOn` and no later than
`dueOn`; an operator adjusts dates first for an early/late handover. Overdue is
derived, never stored as a lifecycle state, beginning at Dublin midnight after
`dueOn`. Invalid dates/transitions receive `422`; an unavailable Item or racing
allocation receives `409`.

The notification/reminder interface carries the settled delivery matrix. On
committed Loan outcomes, call the existing Notification API after the Inventory
transaction for: the borrowing Member on approval, manual rejection, operator
cancellation, and due-date change; every Inventory Operator on a new request,
Member cancellation, and overdue; and the borrowing Member on overdue. Do not
notify checkout, return, ordinary Item edits, or automatic competing-request
rejection. Notification bodies link to the entitled self Loan, operator Loan
detail, or operator queue; only approval also includes approved dates and the
Container path. The reminder ledger schedules one pre-due notification 24 hours
before the Dublin due instant, one immediate overdue notification, then one
every seven days until return. It expands every recipient class to one ledger
row per recipient Principal and stores `loan_id`, `recipient_principal_id`,
kind, and due-date revision as its idempotency key; terminal states and
due-date changes cancel/supersede pending reminders. Add a nullable `idempotency_key` to
`notifications` with a unique non-null index, and extend the existing sole
Notification creation API—not a second raw/public path—to accept that key.
Its own transaction inserts idempotently and broadcasts only when it inserted a
new row. The scheduled worker claims a due ledger entry, calls that idempotent
Notification API with the ledger key, then marks the entry delivered. A crash
after the Notification commits but before the ledger update is safe: retry
reuses the key, creates no duplicate, and reconciles the ledger to delivered.
The same keyed API is used for all transition notifications whose retry could
otherwise duplicate a recipient-visible event.

This is an intentional extension of the existing Notification contract, not a
silent exception: before the Loan/reminder implementation starts, amend the
owning notification migration specification to supersede its prohibition on an
idempotency contract while retaining its invariants that `Dhc.Notifications`
is the sole creation interface and broadcasts occur only after its committed
insert. The Notification schema/API migration is an explicit prerequisite of
the Loan-reminder slice; without it, do not claim crash-safe no-duplicate
reminders.

Retain legacy operations unchanged and marked **legacy compatibility only**
during the compatibility release. New Svelte pages must not import them. If
external writers exist, migrate them before enabling target mutation or disable
their legacy write access in the announced window. Quantity expansion has no
safe bidirectional adapter.

The compatibility window is **read-only for every legacy Inventory mutation**:
after the approved backfill and before target catalog reads/commands are
enabled, disable legacy POST/PATCH/DELETE Item, Category, and Container routes
plus legacy move/maintenance commands with a clear `409` migration response.
The legacy Svelte release may still use its GET responses until the paired
target frontend is deployed, but it cannot create divergent legacy state.
Existing callers are identified by the profile telemetry and either upgraded
before this gate or held until target commands are available. This is a freeze,
not a partial dual-write adapter, because an expanded quantity Item cannot be
translated safely in both directions.

For every spec edit: run `mise run api-gen`, restore/extend hand-written
controllers/renderers as required by the generator caveat, and update all four
manual public-export groups in `packages/api-client/src/index.ts`. Never edit
generated output. Replace Svelte's snake_case Inventory adapters and JSON/default
Valibot logic with target generated types as each target flow lands.

## Rollout sequence

### Release 0 — preparation

1. Add only necessary legacy characterization tests: actor FK/history retention,
   references, and quantity records. Pair each with a target test; do not add
   more tests that bless cascade deletion or boolean Maintenance.
2. Ship and rehearse the profile/mapping/backfill tooling against restored
   production data. Classify anomalies and obtain mapping approval where needed.
3. Freeze unrelated Inventory UI/API changes.

### Release 1 — expand

1. Deploy additive schema and profile/mapping/import tooling; do not expose
   target commands.
2. Rehearse approved backfill against restored production data. Production
   execution waits for Release 3's write freeze and fresh profile snapshot.
3. Deploy code able to read target storage while legacy routes serve legacy GET
   DTOs. Do not enable target reads or commands, or dual-write target commands
   to legacy columns, until the frozen production backfill validates.

### Release 2 — target capabilities

Deliver small slices in this dependency order:

1. operator Structure;
2. operator Items/Maintenance;
3. member Catalog/request/own history and physical label printing;
4. operator Loan queue/commands and notifications/reminders; then
5. optional camera scan adapter.

Gate target reads and commands separately. Exercise them first with designated
test accounts against migrated backup/staging data. Remove legacy navigation
when the target member/operator paths are complete, but retain endpoints only
for the fixed compatibility window and emit aggregate telemetry per legacy call.

### Release 3 — controlled cutover

1. Announce a short Inventory maintenance window and assign cutover commander,
   DB operator, release operator, verifier, and communications owner.
2. Confirm legacy writers are gone; enable maintenance/write freeze; take and
   verify a restorable backup; take the final profile/mapping snapshot; run and
   validate the rehearsed backfill; disable every legacy mutation; and record
   release IDs/migration state.
3. Deploy matching Phoenix target API and SvelteKit frontend together, enable
   target commands, complete smoke checks while maintenance remains on, then
   reopen only if clean.
4. Observe endpoint traffic, command conflict rates, queue counts, reminder
   deduplication, and `401`/`403`/`409`/`422` rates. Forward-migrate or disable
   a remaining legacy client; do not extend legacy API indefinitely.

### Release 4 — contract

After a clean agreed observation period with zero legacy traffic:

- remove legacy OpenAPI operations/generated exports/routes/UI/tests;
- drop `quantity`, `photo_url`, `attributes`, `available_attributes`,
  `attribute_schema`, and `out_for_maintenance`;
- delete generic-history write/controller/render paths while retaining the data
  only as long as retention requires; and
- finalize restrictive FKs and target constraints.

Expand `down/0` is unsafe after target writes/backfills and must raise. Recovery
is verified backup restore plus the matching old Phoenix/SvelteKit release pair,
not production `mix ecto.rollback`.

## Safety controls

- Every destructive/contract migration has zero-anomaly aggregate gates and
  aborts on a mapping, quantity, cycle, collision, orphan, or reference error;
  no skip lists.
- A server-side flag independently stops target catalog reads, target commands,
  and scan/label UI without re-enabling unsafe legacy semantics.
- Preserve verified pre-cutover backup and exact release IDs. On failure: keep
  maintenance enabled, stop writes, preserve aggregate evidence, restore,
  redeploy old pair, smoke test old pair, then reopen.
- Log structured outcomes/reasons and aggregate counters only; do not send Item
  values, notes, or borrower identities to high-cardinality telemetry.
- Photo storage cleanup is an independent approved operation after DB/API
  retirement and ownership proof.

## Verification strategy

### Phoenix/database tests

Use the Phoenix Testcontainers/Postgres harness. Exercise public
`Dhc.Inventory` interfaces; use direct SQL only to prove DB invariants that the
interface cannot reveal.

- Slug generation/immutability, quantity expansion provenance, archive/restore
  and hard-delete eligibility.
- Typed properties: false boolean, empty text, decimal precision, option
  membership, requiredness promotion, retirement, identifying order, archived
  value display, and Category-change mapping.
- Case-insensitive/root Container uniqueness, cycle trigger, explicit subtree
  handling, and restrictive deletion.
- Maintenance start/end/open uniqueness, move during Maintenance, archive end
  reason, and every Loan transition/allocation/date/overdue rule from ALE-273.
- Concurrency races: request vs Maintenance, competing approval, approval vs
  archive/move, checkout vs return. Assert one valid committed result without
  sleeps.
- Member/operator projections and authorization; own retained Loan history;
  no borrower/container/Maintenance leakage.
- Notification transactionality/after-commit broadcast, reminder retry
  deduplication, due-date supersession, and no reminder after terminal state.

### API, client, and UI tests

- Keep generated controller contract tests and add authorization, viewer shape,
  `409`, and `422` tests for target operations.
- Regenerate OpenAPI/controller/client together; update exports; run Svelte
  type check and lint. A type mismatch is a contract failure, not an excuse for
  `any` or a legacy adapter.
- The existing Playwright harness migration remains deferred by `CONTEXT.md`.
  Record the target browser scenarios—member browse/request/cancel/history,
  competing approval, handover/return, Maintenance/movement interlocks,
  archive, and QR slug fallback—for that later harness ticket; do not unskip
  the obsolete quantity/JSON suites as part of this delivery.
- Rehearse profile → expand/backfill → target smoke → restore → legacy rollback
  on restored production backup, keeping only aggregate artifacts.

### Production smoke/go-no-go

Record pass/fail before reopening traffic for:

1. target schema version and preflight/backfill aggregate checks;
2. operator Item create/search/printed-slug resolution;
3. Member available/unavailable browse without leakage, request, and cancel;
4. operator approval, competing-request rejection, checkout, return,
   Maintenance, and archive interlock;
5. `401`/`403` role/session behavior; and
6. due-date edit/reminder reconciliation without duplicate notification.

Any gate failure, data mismatch, privacy breach, duplicate reminder, or smoke
failure is a no-go: retain maintenance mode and restore through the verified
path.

## Residual risks and follow-ups

1. Production Inventory shape is unknown until the required read-only profile.
   Restored-backup/read-only production access becomes a hard blocker only for
   the implementing migration ticket.
2. Quantity expansion and malformed JSON require operator judgement in some
   data sets. The reviewed mapping is the safe mechanism; similarity matching
   is prohibited.
3. `notifications` currently has only a body. Links/kinds and stronger
   deduplication may require additive Notification schema/API work in the
   Loan/reminder slice.
4. Legacy actor references and photo storage ownership remain preserved until
   profile evidence proves a safe disposition.
5. QR camera support and printed labels are convenience adapters; neither is a
   prerequisite for correct server-side commands.
