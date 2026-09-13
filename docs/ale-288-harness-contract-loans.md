# ALE-288 harness contract 3/5: Loans (FROZEN)

> Status: **FROZEN 2026-09-13 (IMPL 0/5)**. Contract only — no implementation.
> Intended consumer: parallel implementers of the `inventoryLoan` E2E
> scenario (`Dhc.E2EHarness.seed/2` + `E2EScenarios["inventoryLoan"]`).
> Post as a Linear comment on ALE-288 when agreed; then implement.
>
> Test-matrix rows this contract serves: **M3** (member request), **M4**
> (own history + member cancel), **S5** (operator approval / competition /
> checkout / return smoke). Stories 31–43; operator semantics ALE-286/ALE-298.

## Ubiquitous language (from `CONTEXT.md`, not redefined here)

- **Loan** — a retained member request to borrow one item. The record survives
  rejection, cancellation, checkout, return, and item archival. It retains the
  approving operator and, when applicable, checkout/return times and operators;
  checkout also identifies the borrowing member.
- **Overdue is derived, never stored** — a `checked_out` loan past its
  approved due date in `Europe/Dublin` (`ClubCalendar`) days is overdue.
  Extending the due date makes it on time again with no transition to undo;
  a closed loan is never overdue.
- **Approval is the single decision point and the collection entitlement.**
  Approval reserves the item, rejects every competing pending request, and
  snapshots the container path — approval is what entitles the borrower to
  know where to collect (story 15). Before approval there is no entitlement,
  so the location stays hidden (story 45).
- **Retention** — loan records are retained permanently. Items with loan
  history are archived, never hard-deleted.
- No legacy vocabulary in this contract: no queues with claim/ownership, no
  lost/written-off states, no condition subdomain on return, no proxy custody.

## Target modules (paths only)

- `apps/phoenix/lib/dhc/inventory.ex` (seam — all calls go through here)
- `apps/phoenix/lib/dhc/inventory/member_loans.ex` (request for self, member
  cancel pre-checkout, own history; ALE-285)
- `apps/phoenix/lib/dhc/inventory/operator_loans.ex` (approve, reject,
  operator cancel, checkout, return, date edits; notification-free; ALE-296)
- `apps/phoenix/lib/dhc/inventory/operator_loan_queue.ex` (lock-free read
  model projecting `operator_view/2`; ALE-297 — this contract names buckets,
  never duplicates the logic)
- `apps/phoenix/lib/dhc/inventory/loan_notifications.ex` (post-commit keyed
  notifications; ALE-298 — named only to mark the boundary, see Non-goals)
- `apps/phoenix/lib/dhc/inventory/club_calendar.ex` (`today/0`, `on_date/1`,
  `Europe/Dublin`)
- `apps/phoenix/lib/dhc/inventory/loan.ex` (schema: `requested_start_on`,
  `requested_due_on`, `approved_start_on`, `approved_due_on`,
  `approved_container_path_snapshot`, snapshots)
- `apps/phoenix/test/support/e2e_harness.ex`
- `apps/web/e2e/e2eApi.ts`
- OpenAPI reference (read-only): `inventoryMemberLoans.*` + 
  `inventoryOperatorLoans.*` + `inventoryOperatorLoanQueue.show` in
  `apps/phoenix/priv/api/openapi.yaml`

## Scenario name

`inventoryLoan` — **one** scenario with a `preset` enum, NOT one scenario per
state. Later contracts (`inventoryMaintenance`, `inventoryArchive`,
`inventoryCatalog`) take the `loanId`/`itemId` this scenario returns as
foreign keys. Structure always comes from `inventoryStructure`, items from
`inventoryItem`, members from `member` — this seed takes ids, never
names/labels/emails.

## Preset table (preset → resulting state + visible UI effect)

| `preset` | Resulting loan status | Visible UI effect (what Playwright asserts) |
|---|---|---|
| `requested` | `requested` | Member sees the request in own history (`/inventory/loans/mine`); operator sees it in queue `pending_requests`. No container path anywhere (story 45). Item still requestable by others (competing requests coexist, story 34). |
| `approved` | `approved` | Borrower sees the loan with its **container path** (collection entitlement, story 15) and approved dates; operator sees it in `handovers_due` once the start arrives (future-dated approvals are in no bucket). Item is held: further requests surface `:item_unavailable`. |
| `checkedOut` | `checked_out` | Borrower sees the loan as live with container path; operator sees it in `returns_and_overdue`. Item is held. `checked_out_at` is set; start is now immutable. |
| `returned` | `returned` | Closed record in member history with return fact; in **no** queue bucket (finished work). Item is requestable again. Never overdue however late it was. |
| `rejected` | `rejected` | Closed record in member history with the operator note; in no queue bucket. Item stays available for another request. |
| `cancelled` | `cancelled` | Closed record in member history. Which actor cancelled is in `decided_by_principal_id` (borrower = member cancel pre-checkout; operator = operator cancel of an approved loan). In no queue bucket. |
| `overdue` | `checked_out` + derived `overdue? = true` | Same UI as `checkedOut`, plus overdue urgency: top of `returns_and_overdue` (earliest due first) and member-visible overdue flag. There is **no** `overdue` status — the seed fabricates elapsed time (see `dueOffsetDays`), never a stored state. |
| `competingPair` | **two** `requested` loans on one item | Two borrowers each see their own request; operator sees **two** rows in `pending_requests`. The allocation test (approve one → the other auto-rejects with the system note) runs live in the spec — the seed leaves both pending. Pair result shape, no flat `loanId`. |

## Attrs

Top-level attrs object (camelCase, harness convention). `preset` selects the
lifecycle path; every other field feeds that path:

| Field | Type | Required | Notes |
|---|---|---|---|
| `preset` | `"requested"` \| `"approved"` \| `"checkedOut"` \| `"returned"` \| `"rejected"` \| `"cancelled"` \| `"overdue"` \| `"competingPair"` | yes | Single scenario, enum-selected path. |
| `itemId` \| `itemSlug` | string (uuid \| `item-NNNNNN`) | yes (one of the two) | `Item.id` / `Item.slug` from `inventoryItem`. Must resolve to an active, available item at seed time unless the preset's own setup creates the blocking state (e.g. `overdue` backdates). Archived/missing surfaces `:not_found`, never falls back. |
| `borrowerMemberId` | string (uuid) | yes, except `competingPair` | Principal id of the borrowing member. This is the **only** borrower input: the seed calls `MemberLoans.request_loan/3` with this id as borrower, proving member-only-self — there is no second "on behalf of" parameter anywhere on this path. |
| `borrowerMemberIds` | array of 2 uuids | yes iff `preset` is `"competingPair"` | The two competing borrowers. Replaces `borrowerMemberId` (supplying both is an arity error). |
| `startsOn` | string (ISO date) | no (default = club `today`) | Requested start. Member rule: today or later in `Europe/Dublin`, due ≥ start. Approval may adjust (including into the past — by decision time the requested start can legitimately have passed). |
| `dueOn` | string (ISO date) | no (default = `startsOn` + 7 days) | Requested due. Member rule: on or after start. |
| `note` | string \| null | no (default `null`) | Request note on the member path; decision note on operator reject/cancel paths (≤1000). Empty/whitespace-only clears to `null`. Non-textual input surfaces, never coerced. |
| `operatorActorId` | string (uuid) | yes iff the preset performs an operator transition (`approved`, `checkedOut`, `returned`, `rejected`, `cancelled` via the operator path, `overdue`) | Principal id for `decided_by` / handover attribution. SHOULD differ from the borrower (attribution hygiene); the seed does not enforce inequality. Missing → harness arity error, no system actor. `requested` and member-cancelled `cancelled` never take it. |
| `cancelledBy` | `"member"` \| `"operator"` | no (default `"member"`), only on `preset: "cancelled"` | `"member"` → `MemberLoans.cancel_loan/3` as the borrower (valid on `requested` or `approved`; seed cancels from whichever state the preset built). `"operator"` → `OperatorLoans.cancel_operator_loan/3` (valid **only** on `approved` — the seed builds `approved` first; pending → reject and checked-out → return are different presets, not this flag). |
| `dueOffsetDays` | integer > 0 | no (default `3`), only on `preset: "overdue"` | How far past due the loan is, in club-calendar days (`today − approved_due_on`). Controls queue top-ordering and reminder-owed assertions downstream. |

Date/actor wiring per preset (which domain calls the seed makes, in order):

- `requested`: `MemberLoans.request_loan(item, {startsOn, dueOn, note}, borrower)`.
- `approved`: request as above, then `OperatorLoans.approve_loan(id, {startsOn?, dueOn?, note?}, operator)` — approval defaults to the requested dates when no override is given and snapshots the container path.
- `checkedOut`: request → approve (window arranged to contain today), then `OperatorLoans.check_out_loan(id, %{}, operator)`.
- `returned`: request → approve → checkout, then `OperatorLoans.return_loan(id, operator)`.
- `rejected`: request, then `OperatorLoans.reject_loan(id, {note?}, operator)`.
- `cancelled` (`cancelledBy: "member"`): request [→ approve], then `MemberLoans.cancel_loan(id, {note?}, borrower)`.
- `cancelled` (`cancelledBy: "operator"`): request → approve, then `OperatorLoans.cancel_operator_loan(id, {note?}, operator)`.
- `overdue`: request → approve → checkout with a window containing today, then the **harness-only time-travel write**: backdate `approved_due_on` to `today − dueOffsetDays` (and `checked_out_at` to a handover day ≤ the new due date, preserving the `due ≥ handover-day` invariant). This write is a fixture escape hatch, not a domain command — it simulates elapsed wall-clock time the seed cannot otherwise produce, because checkout gates to a window containing today while overdue needs a due date in the past.
- `competingPair`: two `MemberLoans.request_loan/3` calls on the **same** item with the same dates, one per `borrowerMemberIds` entry. Both stay `requested`. The seed performs **no** approval — the spec approves one live and asserts the other auto-rejects.

## Result

Viewer-neutral ids (camelCase, **not** rendered JSON blobs — the harness
returns plain maps, never `*JSON.render/2` output). Single-loan presets
return the flat row; `competingPair` returns the pair shape only:

| Field | Type | Notes |
|---|---|---|
| `loanId` | string (uuid) | `Loan.id`. The FK later seeds use. Absent on `competingPair` (see below). |
| `status` | `"requested"` \| `"approved"` \| `"checked_out"` \| `"returned"` \| `"rejected"` \| `"cancelled"` | Stored status. `overdue` never appears here — it is derived. |
| `overdue` | boolean | Derived (`status == "checked_out" && today > approved_due_on` in club days). `true` only on the `overdue` preset. |
| `itemId` | string (uuid) | Echo of the loaned item. |
| `slug` | string (`item-NNNNNN`) | Item slug snapshot (borrower-history display fact, survives archival). |
| `borrowerMemberId` | string (uuid) | Echo of the borrower. Absent on `competingPair` (see below). |
| `startsOn` | string (ISO date) | Requested start for `requested`; approved start once approved (approval defaults to requested when unadjusted). Canonical harness date — specs use it verbatim, never reformat a JS `Date` across the zone boundary. |
| `dueOn` | string (ISO date) | Requested due for `requested`; approved due once approved. Same canonical-date rule. |
| `containerPath` | string \| null | Collection entitlement (story 15/45): the approval snapshot (`"Cage › Rack 2"` shape) for `approved` and later; **`null` for `requested`/`rejected`/member-`cancelled`-from-requested and for both `competingPair` rows**, even though the operator projection technically carries a snapshot — the harness returns the member-visible rule so specs cannot assert a leak. |
| `decidedBy` | string (uuid) \| null | `decided_by_principal_id` echo: operator on approve/reject/operator-cancel, borrower on member cancel, `null` on open loans. Lets M4 assert *who* closed the loan. |

`competingPair` result shape (mirrors the item contract's pair convention —
no flat `loanId` alongside, so callers cannot accidentally use one loan when
they asked for two):

| Field | Type | Notes |
|---|---|---|
| `loans` | array of the row above (length 2) | Same `itemId`, distinct `loanId`/`borrowerMemberId`, both `requested`, both `containerPath: null`. Order matches `borrowerMemberIds` input order. |
| `itemId` | string (uuid) | Echo of the contested item. |

## Rules to pin

Seed-visible consequences of domain rules (the seed assumes valid input; it
does not exercise error paths beyond surfacing caller mistakes):

- **Approval atomically rejects competitors with the system note.** Approving
  one request closes every other `requested` row on the same item in the same
  transaction (`"Rejected automatically: another request for this item was
  approved."`). The approval in the `approved`/`checkedOut`/`returned`/
  `overdue` presets performs this closure silently when no competitors exist;
  the `competingPair` preset exists so a spec can watch it happen live (story
  35). Automatic rejections are silent (no notification — story 49, handoff
  04's boundary).
- **Start immutable after checkout; due stays editable.** The seed never edits
  dates except through the preset paths above. A spec that needs an early/late
  handover edits the approved dates *first* via the operator date-edit route,
  then checks out — the seed for `checkedOut` already arranges a checkable
  window so the smoke test never needs this. Due edits notify + reschedule
  (handoff 04); the reschedule is free (`due_on_revision` derived), which is
  why loan commands stay reminder-free — stated here, asserted there.
- **Checkout gated to window + out-of-maintenance.** `checkedOut`/`returned`/
  `overdue` seeds arrange an approved window containing club `today` on a
  maintenance-free item. An early/late handover or an item under maintenance
  is a spec-level error path (`:outside_window` / `:maintenance_open`), not a
  seed variant.
- **Member cancel only pre-checkout; operator cancel only approved.** Member
  cancel covers `requested`/`approved` (idempotent on already-cancelled, so a
  repeated tap is not an error); after checkout release is the operator's
  return. Operator cancel applies **only** to `approved` — pending is
  rejected, checked-out is returned. `cancelledBy` selects which one the
  `cancelled` preset builds; the other transition is never substituted
  silently.
- **No proxy custody.** The borrower is always the requesting member; checkout
  hands the item to the approved borrower, never to a third party named at
  handover. There is no borrower parameter on the member path to abuse — the
  seed's single `borrowerMemberId` is the proof.
- **Container path is an approval entitlement, not an item fact.** Snapshotted
  at approval; a later container move does not rewrite where the borrower was
  told to go. The harness returns `null` before approval so member-UI specs
  assert absence (story 45), while operator-UI specs read the same loan
  through the operator projection.

## Queue-bucket assertions (which presets land where — no logic duplicated)

The queue (`OperatorLoanQueue`) is a lock-free read model over the same rows;
the seed names the expected bucket per preset so specs assert placement
without reimplementing partitioning. Bucket membership (story 50: every open
loan except a future-dated approval is in exactly one):

| Preset | Expected bucket | Notes for the asserting spec |
|---|---|---|
| `requested` (each `competingPair` row) | `pending_requests` | Oldest first. Count is `length(rows)` — assert both together. |
| `approved` with start arrived | `handovers_due` | Carries advisory `ready_for_checkout?`; the seed arranges `true` (window contains today, no maintenance). A lapsed window would still be here with `false` — not a seed variant. |
| `approved` with future start | **no bucket** | Nothing to hand over today. The seed defaults to an arrivable start; a spec needing this case passes an explicit future `startsOn`/`dueOn` on the `approved` preset. |
| `checkedOut`, `overdue` | `returns_and_overdue` | Earliest approved due first — `overdue` sorts above on-time loans; use `dueOffsetDays` to order multiple overdue seeds deterministically. Overdue is derived urgency on the same physical action (get it back), never a separate bucket. |
| `returned`, `rejected`, `cancelled` | **no bucket** | Finished work, however late a returned loan was. |
| (maintenance bucket) | `open_maintenance` | Not produced by any loan preset — handoff 04's `inventoryMaintenance` owns it. Loan seeds never create periods. |

## Out of scope for the seed (assumes valid input)

- **Notifications** (approval/rejection/cancel/due-change bodies, keyed
  idempotency, silent checkout/return/auto-rejection) — handoff 04's
  reconciliation preset owns all notification assertions. This seed exercises
  the transitions; it never reads the notification table.
- **Reminders** (ledger-is-schedule, at-most-one owed occurrence, retry
  idempotency, closed loans owe nothing, due-edit reschedules for free) —
  handoff 04's `reminderState` flag owns them. The `overdue` preset only sets
  up the derived state reminders later observe.
- **Availability projection details** (`available` / `on_loan` /
  `maintenance` reasons, catalog filtering) — owned by the catalog/queue
  reads; the seed asserts nothing beyond the surfacing rules below.
- **Date-edit and move/maintenance/archive interlocks as error paths**
  (`:start_immutable`, `:outside_window`, `:maintenance_open`,
  `:loan_active` on archive) — operator API tests, not fixtures. The seed
  arranges states where the happy path is reachable.

## Validation: surface vs. accept

Seeds fail fast on caller mistakes; they never paper over conflicts with
fallbacks. Concretely, the implementer maps:

**Surface (raise / return harness 422-or-409 — never silent):**

- Missing/unknown/archived `itemId`/`itemSlug` → `:not_found` (archived slugs
  answer absent, never "archived").
- Unavailable item at request time (open maintenance, live approved/
  checked-out loan) → `:item_unavailable` with the generic reason only —
  never a borrower, date, or maintenance note.
- Member date violations (start in the past in club days, due before start,
  malformed/missing dates) → `:invalid_dates`.
- Second pending request by the same member on the same item →
  `:duplicate_request` (competing *distinct*-borrower requests coexist —
  that is the `competingPair` preset, not an error).
- Missing `borrowerMemberId` (or `borrowerMemberIds` on `competingPair`,
  or both supplied together) → harness arity error.
- Missing `operatorActorId` on any operator-transition preset → harness arity
  error, no system actor.
- `cancelledBy: "operator"` on a non-`approved` loan, member cancel after
  checkout, checkout outside the window or under maintenance, start edit after
  checkout → the domain reason (`:not_approved`, `:not_cancellable`,
  `:outside_window`, `:maintenance_open`, `:start_immutable`). The seed
  arranges valid states, so these surface only when a spec composes presets
  into an illegal sequence.
- Over-length `note` (>1000), non-textual `note` → `:invalid_note` /
  changeset error.

**Silently accept / normalize (documented defaults, not errors):**

- Omitted `startsOn` → club `today`; omitted `dueOn` → `startsOn + 7 days`.
- Omitted `note` → `null`; empty/whitespace-only `note` → `null`.
- Omitted `cancelledBy` on `cancelled` → `"member"`.
- Omitted `dueOffsetDays` on `overdue` → `3`.
- `overdue` backdate preserving `due ≥ handover-day`: the time-travel write
  keeps `checked_out_at` on a day ≤ the new due date (same-day return remains
  a legal loan).
- Cancelling an already-`cancelled` loan (member path) → idempotent no-op
  success, not an error.
- Label casing/whitespace in notes: passed through trimmed, never
  pre-normalized beyond the domain's trim-then-slice.

## Cleanup semantics (`delete_fixture` / `update_fixture`)

Retention (from `CONTEXT.md`): loan records are retained permanently. There
is **no** member/operator delete endpoint — the domain never deletes loans.
E2E teardown breaks this rule deliberately and narrowly:

- `delete_fixture("inventoryLoan", loanId)`:
  - Test-only escape hatch: hard-deletes the loan row (both `competingPair`
    entries deleted individually — no bulk pair delete). Asserts row absence.
  - Never cascades: items, members, periods, categories, containers are left
    untouched. A loan whose item was archived stays archived after the loan
    row is removed (history-absence does not un-archive).
  - Production retention is unaffected — no domain delete function is created
    to serve this; the harness deletes the row directly.
- `update_fixture("inventoryLoan", …)`:
  - **Not supported.** Loans have no generic patch — each transition is its
    own route (`approve` / `reject` / `cancel` / `checkout` / `return` /
    `dates`), and member edits are limited to cancel. A spec needing a
    changed loan seeds the target preset (or drives the UI/API transition
    live); the fixture helper refuses generic updates rather than emulating a
    transition. `E2EUpdatableFixture` gains no loan member (handoff 05
    owns that union).

## TS side (proposed — implement when this contract is accepted)

```ts
type InventoryLoanPreset =
  | "requested"
  | "approved"
  | "checkedOut"
  | "returned"
  | "rejected"
  | "cancelled"
  | "overdue"
  | "competingPair";

type InventoryLoanSeed = {
  attrs: {
    preset: InventoryLoanPreset;
    itemId?: string;
    itemSlug?: string;
    borrowerMemberId?: string;
    borrowerMemberIds?: [string, string];
    startsOn?: string;
    dueOn?: string;
    note?: string | null;
    operatorActorId?: string;
    cancelledBy?: "member" | "operator";
    dueOffsetDays?: number;
  };
  result: {
    loanId: string;
    status:
      | "requested"
      | "approved"
      | "checked_out"
      | "returned"
      | "rejected"
      | "cancelled";
    overdue: boolean;
    itemId: string;
    slug: string;
    borrowerMemberId: string;
    startsOn: string;
    dueOn: string;
    containerPath: string | null;
    decidedBy: string | null;
  };
};

type InventoryLoanPairSeed = {
  attrs: InventoryLoanSeed["attrs"] & {
    preset: "competingPair";
    borrowerMemberIds: [string, string];
  };
  result: {
    loans: InventoryLoanSeed["result"][];
    itemId: string;
  };
};

// in E2EScenarios:
type E2EScenarios = {
  // …existing…
  inventoryLoan: InventoryLoanSeed;
  // pair seeds use the same scenario name with preset: "competingPair";
  // narrow via Extract when the test needs loans[]:
  // type PairResult = InventoryLoanPairSeed["result"];
};
```

`E2EFixtureType` gains `"inventoryLoan"` automatically via
`Exclude<E2EScenarioName, …>`; `E2EUpdatableFixture` explicitly **excludes**
it (seed/delete-only). `setupFunctions.ts` gets a
`createInventoryLoan(preset, …)` helper in the implementing ticket (not this
contract). Pair creation is the same helper with
`{ preset: "competingPair" }` — no second helper.

## Example payloads

Assumes a `member` seed already returned `memberId` (borrower) and an
operator `memberId` (actor), an `inventoryStructure` seed returned a
container path (`Cage › Rack 2`), and an `inventoryItem` seed returned
`itemId`/`slug`. UUIDs below are illustrative. Dates are club-calendar ISO
dates (`startsOn` = today, `dueOn` = today + 7).

### 1. `requested` — member request, no entitlement yet

Attrs:

```json
{
  "preset": "requested",
  "itemId": "55555555-5555-4555-8555-555555555555",
  "borrowerMemberId": "11111111-1111-4111-8111-111111111111",
  "startsOn": "2026-09-14",
  "dueOn": "2026-09-21",
  "note": "Need a feder for Thursday sparring"
}
```

Result:

```json
{
  "loanId": "a1a1a1a1-a1a1-4a1a-a1a1-a1a1a1a1a1a1",
  "status": "requested",
  "overdue": false,
  "itemId": "55555555-5555-4555-8555-555555555555",
  "slug": "item-000124",
  "borrowerMemberId": "11111111-1111-4111-8111-111111111111",
  "startsOn": "2026-09-14",
  "dueOn": "2026-09-21",
  "containerPath": null,
  "decidedBy": null
}
```

`containerPath: null` — no entitlement before approval (story 45). Usable
for M3 request assertions and queue `pending_requests` placement. No
`operatorActorId`: no operator transition took place.

### 2. `approved` — approval with container-path snapshot + dates

Attrs:

```json
{
  "preset": "approved",
  "itemId": "55555555-5555-4555-8555-555555555555",
  "borrowerMemberId": "11111111-1111-4111-8111-111111111111",
  "startsOn": "2026-09-14",
  "dueOn": "2026-09-21",
  "operatorActorId": "22222222-2222-4222-8222-222222222222"
}
```

Result:

```json
{
  "loanId": "b2b2b2b2-b2b2-4b2b-b2b2-b2b2b2b2b2b2",
  "status": "approved",
  "overdue": false,
  "itemId": "55555555-5555-4555-8555-555555555555",
  "slug": "item-000124",
  "borrowerMemberId": "11111111-1111-4111-8111-111111111111",
  "startsOn": "2026-09-14",
  "dueOn": "2026-09-21",
  "containerPath": "Cage › Rack 2",
  "decidedBy": "22222222-2222-4222-8222-222222222222"
}
```

Approval defaulted to the requested dates and snapshotted the container path
— the borrower now sees where to collect (story 15). Usable for S5 approval
smoke and `handovers_due` placement (start has arrived). Any competing
pending request on the item was atomically rejected with the system note.

### 3. `competingPair` — two pending requests on one item

Attrs:

```json
{
  "preset": "competingPair",
  "itemId": "55555555-5555-4555-8555-555555555555",
  "borrowerMemberIds": [
    "11111111-1111-4111-8111-111111111111",
    "33333333-3333-4333-8333-333333333333"
  ],
  "startsOn": "2026-09-14",
  "dueOn": "2026-09-21"
}
```

Result:

```json
{
  "loans": [
    {
      "loanId": "c3c3c3c3-c3c3-4c3c-c3c3-c3c3c3c3c3c3",
      "status": "requested",
      "overdue": false,
      "itemId": "55555555-5555-4555-8555-555555555555",
      "slug": "item-000124",
      "borrowerMemberId": "11111111-1111-4111-8111-111111111111",
      "startsOn": "2026-09-14",
      "dueOn": "2026-09-21",
      "containerPath": null,
      "decidedBy": null
    },
    {
      "loanId": "d4d4d4d4-d4d4-4d4d-d4d4-d4d4d4d4d4d4",
      "status": "requested",
      "overdue": false,
      "itemId": "55555555-5555-4555-8555-555555555555",
      "slug": "item-000124",
      "borrowerMemberId": "33333333-3333-4333-8333-333333333333",
      "startsOn": "2026-09-14",
      "dueOn": "2026-09-21",
      "containerPath": null,
      "decidedBy": null
    }
  ],
  "itemId": "55555555-5555-4555-8555-555555555555"
}
```

Both pending, no approval performed — the spec approves one live (S5
competition test) and asserts the other flips to `rejected` with the system
note while the winner holds the item. Pair shape only: no flat `loanId` /
`borrowerMemberId` alongside. Both rows sit in queue `pending_requests`.
