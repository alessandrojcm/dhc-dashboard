# ALE-288 harness contract 5/5: TS wiring + fixtures + router (integration, FROZEN)

> Status: **FROZEN 2026-09-13 (IMPL 0/5)**. Contract only — no implementation.
> Intended consumer: the implementer wiring handoffs 01–04 into the runnable
> E2E harness (`E2EScenarios` + `setupFunctions.ts` + `Dhc.E2EHarness`).
> Post as a Linear comment on ALE-288 when agreed; then implement.
>
> Test-matrix rows this contract serves: **M1** (browse), **M2**
> (availability), **M3** (request), **M4** (loans-history / cancel / archived
> snapshot), **S5** (cutover smoke: approval → checkout → return +
> maintenance/archive interlocks + reminder reconciliation). Stories 4–56
> via handoffs 01–04.
>
> References files by path. Duplicates no payload tables from handoffs
> 01–04 — attrs/result shapes live in their contracts; this document names
> only the union members, wrapper signatures, touch-list, legacy decision,
> and the spec → seed mapping.

## Source contracts (read first, not repeated here)

- `docs/ale-288-harness-contract-structure.md` — `inventoryStructure`
  attrs/result (category, definitions/options, container path).
- `docs/ale-288-harness-contract-item.md` — `inventoryItem` attrs/result
  (slug, typed values, placement; deletable vs. archive-only).
- `docs/ale-288-harness-contract-loans.md` — `inventoryLoan` preset enum
  (`requested`, `approved`, `checkedOut`, `returned`, `rejected`,
  `cancelled`, `overdue`, `competingPair`) + attrs/result.
- `docs/ale-288-harness-contract-maintenance.md` — `inventoryMaintenance`
  (`open` | `closed`), `inventoryArchive`, and the `reminderState` flag on
  the loan seed.

## Target modules (paths only)

- `apps/web/e2e/e2eApi.ts` (`E2EScenarios`, `E2EScenarioName`,
  `E2EFixtureType`, `E2EUpdatableFixture`, `seedE2EScenario` /
  `updateE2EFixture` / `deleteE2EFixture` via `x-e2e-harness-key`)
- `apps/web/e2e/setupFunctions.ts` (today only `createMember` /
  `setupWaitlistedUser` / `setupInvitedUser` / `createWorkshop` — no
  inventory wrappers yet)
- `apps/phoenix/test/support/e2e_harness.ex` (`seed/2`,
  `delete_fixture/2`, `update_fixture/3`, `reset!/0` truncates all +
  restores base settings)
- `apps/phoenix/test/support/e2e_harness_controller.ex` (generic
  `seed` / `delete_fixture` / `update_fixture` dispatch on strings)
- `apps/phoenix/lib/dhc_web/router.ex:75-101` (`/api/e2e` scope,
  `E2E_SERVER=true` only)
- `apps/web/e2e/AGENTS.md` (disposable PG per run, `POST /api/e2e/reset`
  in global-setup, `loginAsUser()` via `_dhc_session` cookie, one
  Playwright worker, `serviceWorkers: block`, `viewport: null`)
- Domain seam (calls go through here, never around it):
  `apps/phoenix/lib/dhc/inventory.ex` delegating to `Structure`,
  `OperatorItems`, `OperatorItemLifecycle`, `MemberCatalog`,
  `MemberLoans`, `OperatorLoans`, `OperatorLoanQueue`, `LoanReminders`.

## 1. Type-union diff (`apps/web/e2e/e2eApi.ts`)

### 1a. `E2EScenarios`: add five, remove two

```ts
type E2EScenarios = {
  member: MemberSeed;
  waitlist: WaitlistSeed;
  invitation: InvitationSeed;
  workshop: WorkshopSeed;
  registration: RegistrationSeed;
  waitlistStatus: WaitlistStatusSeed;
  setting: SettingSeed;
  // NEW — handoffs 01–04 (attrs/result shapes defined there, not here):
  inventoryStructure: InventoryStructureSeed;
  inventoryItem: InventoryItemSeed;
  inventoryLoan: InventoryLoanSeed; // includes optional reminderState flag + owedKind/notificationKey
  inventoryMaintenance: InventoryMaintenanceSeed;
  inventoryArchive: InventoryArchiveSeed;
  // REMOVED — see §5 legacy decision:
  // inventoryCategory: InventoryCategorySeed;
  // inventoryContainer: InventoryContainerSeed;
};
```

`E2EScenarioName` (`keyof E2EScenarios`) and `E2EFixtureType`
(`Exclude<E2EScenarioName, "setting" | "waitlistStatus">`) update
automatically — no hand-edit beyond the map itself. The five new names
flow through the existing generic `seedE2EScenario<S>` /
`deleteE2EFixture` signatures with no helper change.

Consequence for `E2EFixtureType`: it gains the five inventory names and
loses the two legacy names, so `deleteE2EFixture("inventoryLoan", …)`
etc. typecheck while `deleteE2EFixture("inventoryCategory", …)` stops
compiling — which is the intended forcing function (see §5).

### 1b. `E2EUpdatableFixture`: structure + item only

Current:

```ts
type E2EUpdatableFixture =
  | "inventoryCategory"
  | "inventoryContainer"
  | "registration"
  | "workshop";
```

Proposed:

```ts
type E2EUpdatableFixture =
  | "inventoryStructure"
  | "inventoryItem"
  | "registration"
  | "workshop";
```

Why only these two:

- `inventoryStructure` — category rename and container rename are
  genuine PATCH-class edits the specs need for setup drift (e.g. rename
  a container, then assert the operator viewer reflects it). Container
  moves are explicitly **not** part of `update_fixture` (the structure
  contract excludes `parentContainerId` changes — moves are the separate
  `move_container` command). Definition retire is a command, not a patch
  — it stays out of `update_fixture`.
- `inventoryItem` — notes/values edits are the only generic item patch
  (the domain keeps move / maintenance / archive / reclassify as
  separate commands). The update path maps to
  `OperatorItems.update_operator_item/3`.
- `inventoryLoan` — **excluded**. Every loan mutation is its own route
  (approve / reject / cancel / checkout / return / edit-dates); there is
  deliberately no generic loan PATCH (handoff 03). Date moves the specs
  need are driven live through the operator date-edit route, not through
  the harness.
- `inventoryMaintenance` / `inventoryArchive` — **excluded**
  (seed/delete-only, handoff 04). Periods have no patch (open → the
  `closed` preset's end command; closed → immutable); archive has no
  patch (restore is cleanup, not an edit); reminder geometry changes by
  re-seeding the loan flag.

## 2. `setupFunctions.ts` wrappers (proposed signatures)

Conventions shared by all four wrappers (matching `createMember` /
`createWorkshop`):

- Thin over `seedE2EScenario` — defaults fill boring fields, ids are
  always explicit inputs (seeds take ids, never names/labels/emails).
- Each returns `{ ...seededResult, cleanUp() }`. `cleanUp` never throws
  past the first failure silently — teardown order is the caller's
  responsibility (see §2b). A failing browser assertion must not skip
  cleanup (`try/finally` at the spec level, per `apps/web/e2e/AGENTS.md`).
- Actor ids (`operatorActorId`) are explicit required params — no system
  actor, no hidden operator creation. Specs create their operator via
  `createMember({ roles: new Set(["quartermaster"]) })` and pass it in,
  so attribution stays visible.

```ts
createInventoryStructure(params?: {
  categoryName?: string;          // default: unique "E2E Category <rand>"
  definitions?: Array<...>;       // default: one required text definition; shape per handoff 01
  containerPath?: string[];       // default: ["E2E Cage <rand>", "Rack <rand>"] — root names are globally unique
  operatorActorId: string;        // required — container creation actor
}): Promise<{
  categoryId: string; definitionIds: string[]; optionIds: string[];
  containerIds: string[];
  cleanUp(): Promise<void>;       // containers deepest-first, then category (retires then hard-deletes value-free definitions/options); surfaces dependency blocks, never force-deletes
}>;

createInventoryItem(params: {
  categoryId: string;             // required — from createInventoryStructure
  containerId: string;            // required — placement at seed time (moves go through the live move route)
  values?: Record<string, ...>;   // default: minimal valid values for the category
  notes?: string | null;
  actorId: string;                // required — created_by / lifecycle attribution (item contract: always required)
  withDuplicateLabel?: boolean;   // default false — pair seed, same shape as contract flag
  archived?: boolean;             // default false — delegates to the archive command per the item contract
  inMaintenance?: boolean;        // default false — delegates to start-maintenance per the item contract
}): Promise<{
  itemId: string; slug: string; label: string; categoryId: string;
  deletable: boolean;             // echo so specs know which cleanup path applies
  cleanUp(): Promise<void>;       // history-free → hard-delete; with loan/maintenance history → archive (never delete)
}>;

createInventoryLoan(params: {
  preset: "requested" | "approved" | "checkedOut" | "returned" | "rejected" | "cancelled" | "overdue" | "competingPair";
  itemId?: string;                // exactly one of itemId/itemSlug required
  itemSlug?: string;
  borrowerMemberId: string;       // required (single-borrower presets); ignored for competingPair — see below
  borrowerMemberIds?: [string, string]; // required iff preset === "competingPair" (contract name, not `borrowers`)
  startsOn?: string;              // ISO date; default: club today
  dueOn?: string;                 // ISO date; default: today + 7
  dueOffsetDays?: number;         // overdue backdate; default 3
  note?: string | null;
  operatorActorId?: string;       // required for every preset past requested
  cancelledBy?: "member" | "operator"; // only on preset "cancelled"; default "member" per contract
  reminderState?: "preDue" | "overdue" | "weekly";  // handoff 04 flag; live presets only
}): Promise<{
  loanId: string; status: string; slug: string; borrowerMemberId: string;
  startsOn: string; dueOn: string; containerPath: string | null;
  owedKind: string | null; notificationKey: string | null;
  loans?: Array<{ loanId: string; status: string; slug: string; borrowerMemberId: string; startsOn: string; dueOn: string; containerPath: string | null }>; // competingPair only — pair rows, no flat loanId use
  cleanUp(): Promise<void>;       // hard-deletes loan row(s) + reminder ledger rows; leaves notifications (keyed idempotency makes leftovers harmless)
}>;

createOpenMaintenance(params: {
  itemId?: string;                // exactly one of itemId/itemSlug required
  itemSlug?: string;
  reason: string;                 // required — no default
  operatorActorId: string;        // required
}): Promise<{
  periodId: string; itemId: string; slug: string; open: boolean; // always true
  cleanUp(): Promise<void>;       // ends the period with the canned teardown note; never deletes period rows
}>;
```

Notes:

- No `createInventoryArchive` wrapper: archiving is the item-cleanup
  path (`createInventoryItem(...).cleanUp()` archives when `deletable`
  is false) plus the one-shot `seedE2EScenario("inventoryArchive", …)`
  call for specs that need the `catalogHidden`/`historyKept` proofs.
  A named wrapper would suggest archive is a setup primitive rather
  than the retention rule firing.
- No `closed`-maintenance wrapper: specs needing a closed period seed
  `inventoryMaintenance` with `preset: "closed"` directly (one call),
  keeping the wrapper surface to the S5 interlock primitive (open).
- `createInventoryLoan` is the only wrapper taking a `preset` enum —
  one scenario, enum-selected path (handoff 03), not one helper per
  state.

### 2b. Cleanup ordering + sandbox note

Retention: loans + maintenance periods are retained permanently; items
with that history archive, never hard-delete
(`docs/ale-288-harness-contract-maintenance.md` § Cleanup). E2E teardown
breaks retention narrowly and only for loans/ledger rows (test-only
hard-delete). Durable fixtures deleted outside the per-test sandbox
transaction must be removed explicitly in `on_exit/1` (see
`docs/agents/commands.md` — `Ecto.Adapters.SQL.Sandbox.unboxed_run/2`
callers own teardown); the same discipline applies here at the spec
level: every wrapper's `cleanUp()` runs in `afterEach`/`afterAll`
regardless of assertion outcome.

Required teardown order (reverse of creation):

1. loans (`createInventoryLoan.cleanUp`) — frees the `:loan_active`
   block on maintenance/archive/item cleanup;
2. open maintenance (`createOpenMaintenance.cleanUp` — end, not delete);
3. archive restore is **not** a teardown step — archived items stay
   archived unless the spec explicitly restores live;
4. items (`createInventoryItem.cleanUp` — delete iff `deletable`, else
   archive);
5. structure (`createInventoryStructure.cleanUp` — containers
   leaf-first, then category).

## 3. `reset!/0` impact (`apps/phoenix/test/support/e2e_harness.ex:29-58`)

No change needed beyond the new tables being covered by the existing
implementation:

- `reset!/0` truncates **every** table in `public` except
  `schema_migrations` (`TRUNCATE … RESTART IDENTITY CASCADE`) and then
  restores the two base settings (`waitlist_open`, `hema_insurance_form_link`).
- The five new scenarios write only to ordinary application tables
  (categories, definitions, options, containers, items, item values,
  maintenance periods, loans, loan reminders, notifications) — all under
  `public`, all truncated safely by the existing query. There is no
  legacy `inventory_history` table to consider (ALE-289 deleted it
  outright, with its slice).
- No new base settings are needed: no inventory seed depends on a
  `settings` row, and no spec asserts a default setting the reset does
  not already restore.

## 4. Router / controller (`router.ex`, `e2e_harness_controller.ex`)

No new routes. The existing generic dispatch already covers the five
new scenario names:

- `POST /api/e2e/seed/:scenario` → `E2EHarness.seed(scenario, attrs)` —
  the `:scenario` segment is an opaque string; adding
  `inventoryStructure` / `inventoryItem` / `inventoryLoan` /
  `inventoryMaintenance` / `inventoryArchive` needs only new `seed/2`
  clauses in `apps/phoenix/test/support/e2e_harness.ex`, no router or
  controller edit.
- `PATCH /api/e2e/fixtures/:type/:id` → `update_fixture(type, id, attrs)`
  and `POST /api/e2e/fixtures/:type/:id` → `delete_fixture(type, id)` —
  likewise string-dispatched. Only `e2e_harness.ex` gains clauses:
  `update_fixture` for `inventoryStructure` + `inventoryItem`,
  `delete_fixture` for all five.

`apps/phoenix/test/support/e2e_harness_controller.ex` is therefore in
the touch-list as **read-only / no-change** (verify generic dispatch,
do not add actions).

## 5. Legacy decision: remove `inventoryCategory` / `inventoryContainer`

**Recommendation: delete, do not adapt.**

- Unused by any spec: ALE-289 deleted the four inventory Playwright
  specs (`inventory-categories`, `inventory-containers`,
  `inventory-full-lifecycle`, `inventory-items`) and the `inventoryItem`
  e2e seed; nothing calls `seedE2EScenario("inventoryCategory" | "inventoryContainer")` today.
- Wrong shape to adapt: the legacy seeds serve the ALE-104/105
  quantity/JSON-attributes model (`available_attributes`,
  `attribute_schema`); the target model is one-row-per-unit with typed
  value rows, derived labels, and projected availability. An adapter
  translating legacy attrs to target calls would hide exactly the
  divergence the cutover exists to remove, and would leave two names
  for structure forever.
- Removal plan (one ticket, with the five-scenario implementation):
  1. delete `seed("inventoryCategory")` / `seed("inventoryContainer")`
     + `delete_fixture` + `update_fixture` clauses in
     `apps/phoenix/test/support/e2e_harness.ex:245-254,319-320,343-351`;
  2. delete `InventoryCategorySeed` / `InventoryContainerSeed` and
     their `E2EScenarios` entries in `apps/web/e2e/e2eApi.ts:132-140,183-184`;
  3. drop `"inventoryCategory" | "inventoryContainer"` from
     `E2EUpdatableFixture` (replaced per §1b).
- Migration note for hidden callers: any out-of-tree caller gets a
  harness 422 on the unknown scenario name plus a TS compile break on
  the removed union members — both fail fast at seed time, never
  silently. Before deleting, grep for `inventoryCategory` /
  `inventoryContainer` across `apps/web/e2e/`; the expected result is
  the harness files themselves plus the ALE-289 removal record.

## 6. Touch-list

| File | Change |
|---|---|
| `apps/web/e2e/e2eApi.ts` | Add five seed types to `E2EScenarios` (§1a); rewrite `E2EUpdatableFixture` to `inventoryStructure` + `inventoryItem` + `registration` + `workshop` (§1b); delete legacy seed types. No helper-signature changes. |
| `apps/web/e2e/setupFunctions.ts` | Add `createInventoryStructure`, `createInventoryItem`, `createInventoryLoan`, `createOpenMaintenance` (§2). No changes to existing helpers. |
| `apps/phoenix/test/support/e2e_harness.ex` | Add five `seed/2` clauses, five `delete_fixture/2` clauses, two `update_fixture/3` clauses; delete legacy category/container clauses; `reset!/0` unchanged (§3). |
| `apps/phoenix/test/support/e2e_harness_controller.ex` | No change — verify generic `:scenario` / `:type` dispatch covers the new names (§4). |
| `apps/phoenix/lib/dhc_web/router.ex` | No change — `/api/e2e` scope already generic (§4). |

## 7. Spec → seed mapping (M1–M4 / S5)

| Spec | Seeds (in creation order) | Presets / flags asserted |
|---|---|---|
| M1 browse (catalog list/search/filters) | `member` (viewer) → `inventoryStructure` → `inventoryItem` × N (varied categories/values) | Items `available`; archived items absent via `inventoryArchive` on one row (`catalogHidden: true`). |
| M2 availability | `member` → `inventoryStructure` → `inventoryItem` → `inventoryMaintenance` (`open`, then `closed`) + `inventoryLoan` (`requested`) | `open` → catalog `maintenance`, unrequestable; `requested` loan coexists (pending ≠ unavailable); `closed` → `available` again. Operator reason present / member reason generic (handoff 04). |
| M3 request (member request + validation) | `member` (borrower) → `inventoryStructure` → `inventoryItem` → `inventoryLoan` (`requested`, `competingPair`) | `requested` → own-loan row, container path `null`; `competingPair` → approval-allocation setup for S5. Date/note validation errors surface from the seed. |
| M4 loans-history / cancel / archived snapshot | `member` → `inventoryStructure` → `inventoryItem` → `inventoryLoan` (`approved`, `checkedOut`, `returned`, `rejected`, `cancelled`, member-cancel of `requested`) → `inventoryArchive` | Each preset renders its history row; member cancel pre-checkout only; archived item keeps own-loan snapshots (`historyKept: true`) while catalog answers `:not_found`. |
| S5 cutover smoke (approve → checkout → return + interlocks + reminders) | `member` × 2 (borrowers) + operator → `inventoryStructure` → `inventoryItem` → `inventoryLoan` (`competingPair` → live `approve` → `checkout` → `return` via API) → `inventoryMaintenance` (`open` interlock: start rejects pending, blocked by live loan) → `inventoryArchive` (blocked by live loan, succeeds after return) → `inventoryLoan` + `reminderState: "overdue"` → `LoanReminders.run(today)` | Approval rejects the competitor with the system note + snapshots container path; checkout gated to window + out-of-maintenance; return closes custody; maintenance/archive interlocks return `:loan_active` where expected; one `run` delivers exactly `owedKind` under `notificationKey`, second `run` delivers nothing. |
