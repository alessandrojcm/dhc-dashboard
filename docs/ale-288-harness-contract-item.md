# ALE-288 harness contract 2/5: Operator item (FROZEN)

> Status: **FROZEN 2026-09-13 (IMPL 0/5)**. Contract only — no implementation.
> Intended consumer: parallel implementers of the `inventoryItem` E2E
> scenario (`Dhc.E2EHarness.seed/2` + `E2EScenarios["inventoryItem"]`).
> Post as a Linear comment on ALE-288 when agreed; then implement.

## Ubiquitous language (from `CONTEXT.md`, not redefined here)

- **Item** — one individually tracked physical unit. One row is one physical
  unit with one immutable, system-generated, human-readable slug, one Category,
  and one direct Container (its assigned home storage, not live custody).
  No stored name.
- **Slug** — the item's identity (`item-000001` from
  `inventory_item_slug_seq`). Stable across category changes, never
  operator-writable, resolution key alongside the id.
- **Derived label** — visible label computed from the category name plus that
  category's ordered identifying property values, slug as fallback when no
  identifying value is present. Never stored.
- **Property Definition / value** — stable category-owned definitions of type
  `text` | `decimal` | `boolean` | `single_select`. No defaults. Empty text
  is absence (no value row); boolean `false` is a real value.
- **Notes** — plain-text current facts with no audit history. Empty or
  whitespace-only clears them.
- **Archived Inventory** — items removed from normal browsing without
  destroying identity or retained history. Restore requires live dependencies.
- **Maintenance Period** — immediately-started interval making the item
  unavailable for requests and loans. At most one open per item.
- No legacy vocabulary in this contract: no quantity, no photo, no stored
  label, no stored availability flag.

## Target modules (paths only)

- `apps/phoenix/lib/dhc/inventory.ex` (seam — all calls go through here)
- `apps/phoenix/lib/dhc/inventory/operator_items.ex` (slug, derived label, create/edit/reclassify)
- `apps/phoenix/lib/dhc/inventory/item_values.ex` (typed value validation)
- `apps/phoenix/lib/dhc/inventory/item_projection.ex` (label + availability)
- `apps/phoenix/lib/dhc/inventory/item_guards.ex` (item locking, dependency checks)
- `apps/phoenix/lib/dhc/inventory/operator_item_lifecycle.ex` (move, maintenance, archive/restore/delete — presets delegate here, this contract does not duplicate them)
- `apps/phoenix/lib/dhc/inventory/item.ex` (schema: `slug`, `notes`, `category_id`, `container_id`; virtual `label`, `values`, `availability`)
- `apps/phoenix/test/support/e2e_harness.ex`
- `apps/web/e2e/e2eApi.ts`
- OpenAPI reference (read-only): `inventoryItems.*` operations and
  `InventoryOperatorItem` schemas in `apps/phoenix/priv/api/openapi.yaml`

## Scenario name

`inventoryItem` — one scenario covering a single physical unit. Later
contracts (`inventoryLoan`, `inventoryMaintenance`, `inventoryCatalog`) take
the `itemId`/`slug` this scenario returns as foreign keys and never recreate
items. Structure (category, definitions, options, containers) always comes
from the `inventoryStructure` scenario — this seed takes ids, never
names/labels.

## Attrs

Top-level attrs object (camelCase, harness convention):

| Field | Type | Required | Notes |
|---|---|---|---|
| `categoryId` | string (uuid) | yes | `EquipmentCategory.id` from `inventoryStructure`. Must be active; archived/missing surfaces, never falls back. |
| `containerId` | string (uuid) | yes | `Container.id` (leaf) from `inventoryStructure`. Must be active; archived/missing surfaces. The assigned home storage, not custody. |
| `values` | map `definitionId → value` | no (default `{}`) | Typed rows keyed by `PropertyDefinition.id`. See value shapes below. Omitted → no values (valid only when the category requires nothing). |
| `notes` | string \| null | no (default `null`) | Plain-text current fact (≤1000). Empty/whitespace-only clears to `null`. Non-textual input surfaces, never coerced. |
| `actorId` | string (uuid) | yes | Principal id for `created_by` / lifecycle commands. Fail fast when missing; no system actor. |
| `withDuplicateLabel` | boolean | no (default `false`) | Preset: create **two** items with identical `categoryId` + `values` + `containerId`. Proves duplicates are allowed (slug distinguishes units). Result shape becomes a pair — see below. |
| `archived` | boolean | no (default `false`) | Preset flag: after creating the item, archive it via `OperatorItemLifecycle.archive_operator_item/3`. Composes with handoffs 04/05 (loan/maintenance history rules); this contract does not re-specify archive interlocks. |
| `inMaintenance` | boolean | no (default `false`) | Preset flag: after creating the item, open a maintenance period via `OperatorItemLifecycle.start_operator_item_maintenance/3` with a canned reason (`"E2E seed: routine check"`). Composes with handoff 04 (maintenance lifecycle); this contract does not re-specify period rules. |

Value shapes (one per `value_type`; keys are always `definitionId`):

| `value_type` | Seed value | Notes |
|---|---|---|
| `text` | string | Empty/whitespace-only is **absence** (no row written). Trimmed on write. |
| `decimal` | string \| number | Plain number (`"1.5"`, `1.5`, `2`). Serialized as string on the wire to preserve precision. Non-numeric strings surface `:type_mismatch`. |
| `boolean` | boolean | `false` is a real value (row written). `null`/absent key means no value. |
| `single_select` | string (uuid) | An `optionId` of a **live** option of that same definition. Foreign-definition, unknown, or retired option ids surface (`:unknown_option` / `:retired_option`). |

`values` is the **complete set** on create: every required definition of the
category must be present (after absence-normalization) or the seed surfaces
`:required`. Unknown `definitionId` keys surface `:unknown_definition`;
retired-definition values surface `:retired_definition`. There are no
defaults — the seed never invents a value for an omitted definition.

Preset composition rules:

- `withDuplicateLabel`, `archived`, and `inMaintenance` compose: e.g.
  `{ withDuplicateLabel: true, archived: true }` archives **both** units of
  the pair.
- `archived: true` + `inMaintenance: true` on one seed means: create, open
  maintenance, then archive (archive atomically ends the open period). The
  seed performs the two lifecycle calls in that order; it does not assert
  the intermediate state.
- The presets never **duplicate** handoff 04/05 behavior: this contract pins
  only that the flag delegates to the lifecycle command and what the seed
  returns afterwards. Period reasons, rejection side effects, and loan
  interlocks belong to those contracts.

## Result

Viewer-neutral ids (camelCase, **not** rendered JSON blobs — the harness
returns plain maps, never `*JSON.render/2` output). Minimal keys the
catalog/loan seeds need, plus the cleanup signal:

| Field | Type | Notes |
|---|---|---|
| `itemId` | string (uuid) | `Item.id`. The FK loan/maintenance seeds use. |
| `slug` | string (`item-NNNNNN`) | Immutable server-minted identity. Stable across reclassification. Resolution key alongside `itemId`. |
| `label` | string | Server-derived (`Category · identifying values…`, slug fallback). Echo so callers need not recompute; never used as a FK. |
| `categoryId` | string (uuid) | Echo of the owning category. Catalog/loan seeds use it to avoid a re-read. |
| `deletable` | boolean | Cleanup signal: `true` iff the item has no loan or maintenance rows (history-free → hard-delete allowed). `false` once any preset or later step created history (→ archive, never delete). |

`withDuplicateLabel: true` changes the result shape to a pair:

| Field | Type | Notes |
|---|---|---|
| `items` | array of the row above (length 2) | Same `categoryId`, same `values`, distinct `itemId`/`slug`, identical `label`. |
| `deletable` | boolean | `true` iff **both** units are history-free (always `true` at seed time unless combined with `archived`/`inMaintenance`, which create maintenance history — see below). |

Non-pair seeds return the flat row. Pair seeds return `{ items, deletable }`
only — no flat `itemId`/`slug` alongside, so callers cannot accidentally use
one unit when they asked for two.

## Rules to pin

Seed-visible consequences of domain rules (the seed assumes valid input; it
does not exercise error paths beyond surfacing caller mistakes):

- **Slug immutability across reclassification.** The slug is minted once at
  create and never changes — not on edit, not on category change, not on
  move/archive/restore. The seed returns the slug; later edit flows prove it
  survives. The seed itself never reclassifies.
- **Duplicates allowed.** Identical category/property combinations are valid
  because the slug distinguishes the physical units. `withDuplicateLabel`
  is the proof: two creates with the same attrs yield distinct
  `itemId`/`slug` and identical `label`. No uniqueness error is possible on
  values.
- **Category change requires full new-category values.** Reclassification is
  one atomic command validated against the **new** category's live
  definitions; old values carry over only through explicit operator mapping,
  anything unmapped stops being a current fact. Partial reclassification is
  impossible. The seed never reclassifies — it only guarantees the created
  item is a valid reclassification *source* (all its values satisfy its own
  category). The reclassification gate belongs to operator API tests.
- **Notes are current-facts-only.** Notes overwrite on every edit; there is
  no notes history. The seed sets the initial fact; later edits replace it
  wholesale (empty clears). The seed never appends.

## Out of scope for the seed (assumes valid input)

The seed creates **fresh, valid** items. It does not exercise evolution or
lifecycle gates — those belong to operator API tests, not fixtures:

- **Movement** (`move_operator_item/3`, blocked by a live loan) — never part
  of `seed/2`. The seed places the item once via `containerId`.
- **Maintenance transitions** beyond the `inMaintenance` flag (reason
  required, at most one open, end notes, loan interlocks) — handoff 04's
  problem. The flag delegates; the seed asserts nothing about periods beyond
  returning `deletable: false`.
- **Archive/restore gates** (live category, whole container chain, retained
  values still valid) — handoff 04/05's problem. The `archived` flag
  delegates; the seed returns the archived row.
- **Category change** (`change_operator_item_category/3`) — not part of
  `seed/2`. See `update_fixture` below for the deliberate non-goal.
- **Availability projection** (`available` / `on_loan` / `maintenance` /
  `archived`) — recomputed on every read, never stored, never returned by
  this seed (catalog/loan reads own it).

## Validation: surface vs. accept

Seeds fail fast on caller mistakes; they never paper over conflicts with
fallbacks. Concretely, the implementer maps:

**Surface (raise / return harness 422-or-409 — never silent):**

- Missing/unknown `categoryId` → `:not_found`.
- Archived `categoryId` → `:archived_category`.
- Missing/unknown `containerId` → `:not_found`.
- Archived `containerId` → `:archived_container`.
- Missing `actorId` → harness arity error (fail fast, do not default).
- Per-definition value failures → `:invalid_values` with `valueErrors`
  (`:required`, `:type_mismatch`, `:unknown_option`, `:retired_option`,
  `:retired_definition`, `:unknown_definition`).
- Non-textual `notes` (object, number) → `:invalid_notes`.
- Over-length `notes` (>1000) → changeset error.
- `archived: true` blocked by a live loan → `:loan_active` (only reachable
  when composed with a loan-creating step; a fresh seed never has loans).
- `inMaintenance: true` blocked by a live loan → `:loan_active` (same).
- `withDuplicateLabel` on a category with required-but-unset values fails
  **both** units with `:invalid_values` (no half-pair is returned).

**Silently accept / normalize (documented defaults, not errors):**

- Omitted `values` → `{}` (valid iff the category requires nothing).
- Omitted `notes` → `null`.
- Empty/whitespace-only text value → absence (no row).
- Empty/whitespace-only `notes` → `null` (clears).
- Whitespace-padded text values / notes → trimmed.
- `false` boolean → real value (row written).
- `decimal` numbers (`1.5`) and numeric strings (`"1.5"`) → same stored value.
- Label casing/whitespace in values: passed through untouched.

## Cleanup semantics (`delete_fixture` / `update_fixture`)

Retention (from `CONTEXT.md`): loan records and maintenance periods are
retained permanently. Items with that history are archived, never
hard-deleted. History-free items may be hard-deleted.

- `delete_fixture("inventoryItem", itemId)`:
  - History-free (`deletable: true`) → hard delete via
    `OperatorItemLifecycle.delete_operator_item/2` with explicit confirmation
    (`%{"confirm" => true}`). Deletes value rows + the item row. Asserts row
    absence.
  - With history (`deletable: false`: either preset created a maintenance
    period, or a later loan/maintenance step touched the item) → **archive**,
    never delete. Calls `archive_operator_item/3` (idempotent no-op when
    already archived). Surfaces `:loan_active` (409) when a live loan blocks
    archival — the test must close loans first or assert the 409 deliberately.
    Teardown asserts `archived_at` is set, not row absence.
  - Pair seeds: the caller deletes each `items[]` entry individually (no
    bulk pair delete). Each entry carries its own `deletable` fate.
  - The fixture helper never deletes loans, periods, categories, or
    containers on the caller's behalf — blocked deletions surface, never
    cascade.
- `update_fixture("inventoryItem", itemId, attrs)`:
  - Allowed (partial attrs, same shapes as seed attrs minus presets):
    `notes` + `values` only, mapping to `OperatorItems.update_operator_item/3`.
    Supplying `values` replaces the complete set (omitted definitions become
    absent); omitting `values` leaves stored values untouched.
  - **Refused, surfacing domain errors**: edit on an archived item →
    `:archived` (409, restore first); value failures → `:invalid_values`
    (422). The helper passes these through; it never migrates values to
    satisfy a gate.
  - Not part of this fixture: `containerId` changes (that's the `move`
    command, handoff 04), `categoryId` changes (the atomic reclassify
    command — a later contract if E2E needs it), maintenance/archive
    transitions (handoff 04/05 commands, not generic edits). Supplying them
    here is ignored (mirroring `update_operator_item/3`, which ignores
    `containerId`) or rejected — never silently applied.

Which preset is deletable:

| Seed | `deletable` | Cleanup |
|---|---|---|
| plain / `withDuplicateLabel` (no flags) | `true` | hard delete |
| `inMaintenance: true` (single or pair) | `false` | archive (period is retained history) |
| `archived: true` (single or pair) | `false` | archive is a no-op; assert archived |
| `archived: true` + `inMaintenance: true` | `false` | same (archive ended the period atomically) |
| any item later touched by a loan step | `false` | archive |

## TS side (proposed — implement when this contract is accepted)

```ts
type InventoryItemValue = string | number | boolean;

type InventoryItemSeed = {
  attrs: {
    categoryId: string;
    containerId: string;
    values?: Record<string, InventoryItemValue>;
    notes?: string | null;
    actorId: string;
    withDuplicateLabel?: boolean;
    archived?: boolean;
    inMaintenance?: boolean;
  };
  result: {
    itemId: string;
    slug: string;
    label: string;
    categoryId: string;
    deletable: boolean;
  };
};

type InventoryItemPairSeed = {
  attrs: InventoryItemSeed["attrs"] & { withDuplicateLabel: true };
  result: {
    items: InventoryItemSeed["result"][];
    deletable: boolean;
  };
};

// in E2EScenarios:
type E2EScenarios = {
  // …existing…
  inventoryItem: InventoryItemSeed | InventoryItemPairSeed;
  // pair seeds use the same scenario name with withDuplicateLabel: true
  // and return `{ items, deletable }` only. Discriminate on `items`.
};

function isInventoryItemPair(
  result: InventoryItemSeed["result"] | InventoryItemPairSeed["result"],
): result is InventoryItemPairSeed["result"] {
  return "items" in result;
}
```

`E2EFixtureType` gains `"inventoryItem"` automatically via
`Exclude<E2EScenarioName, …>`; `E2EUpdatableFixture` gains it explicitly
(notes/values edits only). `setupFunctions.ts` `createInventoryItem()`
overloads on `withDuplicateLabel: true` and `cleanUp` deletes each
`items[]` entry individually (no bulk pair delete). Pair creation is
the same helper — no second helper.

## Example payloads

Assumes an `inventoryStructure` seed already returned `categoryId`,
`containerId`, and definition/option ids. UUIDs below are illustrative.

### 1. Minimal — valid item with no values

Category has no required definitions.

Attrs:

```json
{
  "categoryId": "22222222-2222-4222-8222-222222222222",
  "containerId": "44444444-4444-4433-8444-444444444444",
  "actorId": "11111111-1111-4111-8111-111111111111"
}
```

Result:

```json
{
  "itemId": "55555555-5555-4555-8555-555555555555",
  "slug": "item-000123",
  "label": "Longsword · item-000123",
  "categoryId": "22222222-2222-4222-8222-222222222222",
  "deletable": true
}
```

Label falls back to the slug because no identifying value is present.
`deletable: true` — no history exists, cleanup hard-deletes.

### 2. Full — item with all four value types

Category `Feder` has `Maker` (text, identifying 0), `Weight (g)` (decimal),
`Club-owned` (boolean, required), `Size` (single_select, identifying 1,
options Short/Standard/Long).

Attrs:

```json
{
  "categoryId": "55555555-5555-4555-8555-555555555555",
  "containerId": "eeeeeeee-eeee-4eee-eeee-eeeeeeeeeeee",
  "values": {
    "66666666-6666-4666-8666-666666666666": "Regenyei",
    "bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb": "1.50",
    "cccccccc-cccc-4ccc-cccc-cccccccccccc": false,
    "77777777-7777-4777-8777-777777777777": "99999999-9999-4999-8999-999999999999"
  },
  "notes": "Chipped tip — re-check after Thursday sparring",
  "actorId": "11111111-1111-4111-8111-111111111111"
}
```

Notes:

- `Maker` → text `"Regenyei"` (identifying, appears in the label).
- `Weight (g)` → decimal as string `"1.50"` (number `1.5` is equivalent).
- `Club-owned` → boolean `false` — a real value, not absence; the row is
  written and renders as `No` in identifying labels.
- `Size` → `optionId` of `Standard` (identifying, label renders the option
  label, not the id). Empty-string text would be absence; it is not used
  here.
- `notes` is a plain current fact.

Result:

```json
{
  "itemId": "ffffffff-ffff-4fff-ffff-ffffffffffff",
  "slug": "item-000124",
  "label": "Feder · Regenyei · Standard",
  "categoryId": "55555555-5555-4555-8555-555555555555",
  "deletable": true
}
```

### 3. Duplicate-label pair — two physical units, one label

Same category/container/values twice via the preset. Proves duplicates are
allowed: the slug distinguishes the units.

Attrs:

```json
{
  "categoryId": "55555555-5555-4555-8555-555555555555",
  "containerId": "eeeeeeee-eeee-4eee-eeee-eeeeeeeeeeee",
  "values": {
    "66666666-6666-4666-8666-666666666666": "Regenyei",
    "77777777-7777-4777-8777-777777777777": "99999999-9999-4999-8999-999999999999"
  },
  "actorId": "11111111-1111-4111-8111-111111111111",
  "withDuplicateLabel": true
}
```

Result:

```json
{
  "items": [
    {
      "itemId": "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa",
      "slug": "item-000125",
      "label": "Feder · Regenyei · Standard",
      "categoryId": "55555555-5555-4555-8555-555555555555",
      "deletable": true
    },
    {
      "itemId": "bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb",
      "slug": "item-000126",
      "label": "Feder · Regenyei · Standard",
      "categoryId": "55555555-5555-4555-8555-555555555555",
      "deletable": true
    }
  ],
  "deletable": true
}
```

Identical `label`, distinct `slug`/`itemId`. Both history-free, so the pair
is hard-deletable entry by entry. Combining with `"archived": true` or
`"inMaintenance": true` would return the same pair shape with
`deletable: false` and archived/maintenance state set by the lifecycle
commands.
