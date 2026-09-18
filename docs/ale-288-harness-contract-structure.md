# ALE-288 harness contract 1/5: Structure (FROZEN)

> Status: **FROZEN 2026-09-13 (IMPL 0/5)**. Contract only — no implementation.
> Intended consumer: parallel implementers of the `inventoryStructure` E2E
> scenario (`Dhc.E2EHarness.seed/2` + `E2EScenarios["inventoryStructure"]`).
> Post as a Linear comment on ALE-288 when agreed; then implement.

## Ubiquitous language (from `CONTEXT.md`, not redefined here)

- **Category** — classification shared by items with the same set of property
  definitions. Cannot be deleted while an item uses it.
- **Property Definition** — stable category-owned definition for an item value.
  Type is `text` | `decimal` | `boolean` | `single_select`. A small ordered
  subset are identifying properties for the derived item label. Label and
  requiredness may change while in use; type may not. Stable identity across
  renames — renaming never rewrites item values.
- **Container** — storage location, nestable, acyclic; moving a container moves
  its whole subtree. Names unique case-insensitively **among siblings**, not
  globally. A root container has no parent.
- No legacy vocabulary in this contract: no `available_attributes`,
  no `attribute_schema`, no quantity, no JSON attribute blobs.

## Target modules (paths only)

- `apps/phoenix/lib/dhc/inventory.ex` (seam — all calls go through here)
- `apps/phoenix/lib/dhc/inventory/categories.ex`
- `apps/phoenix/lib/dhc/inventory/structure.ex`
- `apps/phoenix/lib/dhc/inventory/containers.ex`
- `apps/phoenix/lib/dhc/inventory/equipment_category.ex`
- `apps/phoenix/lib/dhc/inventory/property_definition.ex`
- `apps/phoenix/lib/dhc/inventory/property_option.ex`
- `apps/phoenix/lib/dhc/inventory/container.ex`
- `apps/phoenix/test/support/e2e_harness.ex`
- `apps/web/e2e/e2eApi.ts`
- OpenAPI reference (read-only): `inventoryStructure.*` operations and
  `InventoryPropertyDefinition` / `InventoryPropertyOption` schemas in
  `apps/phoenix/priv/api/openapi.yaml`

## Scenario name

`inventoryStructure` — one scenario covering category + definitions (+ options)
+ container path. Later contracts (`inventoryItem`, `inventoryLoan`,
`inventoryMaintenance`, `inventoryCatalog`) take the ids this scenario returns
as foreign keys and never recreate structure.

## Attrs

Top-level attrs object (camelCase, harness convention):

| Field | Type | Required | Notes |
|---|---|---|---|
| `categoryName` | string (1–50) | yes | Case-insensitive unique. Maps to `Categories.create_category %{name: …}`. |
| `categoryDescription` | string (≤500) \| null | no | Omitted → `null`. |
| `definitions` | array of definition objects | no (default `[]`) | Created in order via `Structure.create_definition/2` + `create_option/2`. |
| `containerPath` | array of string (each 1–100) | no (default `[]`) | Nested names root-first, e.g. `["Cage", "Shelf A"]`. Each level created via `Containers.create_container/2` under the previous level. Sibling-unique case-insensitively. Empty → no containers. |
| `containerDescription` | string (≤500) \| null | no | Applied to the **leaf** container only; intermediate containers get `null`. Keeps the common case (one description) without a parallel array. |
| `actorId` | string (uuid) | yes, when `containerPath` is non-empty | Principal id for `created_by` (NOT NULL column). Category/definition writes need no actor. Required iff containers are created. |

Definition object:

| Field | Type | Required | Notes |
|---|---|---|---|
| `label` | string (1–100) | yes | Case-insensitive unique **within the category**. |
| `valueType` | `"text"` \| `"decimal"` \| `"boolean"` \| `"single_select"` | yes | `decimal` is the plain-number type (spec shorthand "number" maps here). |
| `required` | boolean | no (default `false`) | |
| `identifyingPosition` | integer ≥ 0 \| null | no (default `null`) | Non-null = identifying, orders the derived item label. Unique within the category when set. |
| `options` | array of option objects | required iff `valueType` is `"single_select"`, forbidden otherwise | At least one entry for `single_select`. |

Option object:

| Field | Type | Required | Notes |
|---|---|---|---|
| `label` | string (1–100) | yes | Case-insensitive unique **within the definition**. |
| `position` | integer ≥ 0 | no (default = index in the array) | Display order. |

## Result

Viewer-neutral ids (camelCase, **not** rendered JSON blobs — the harness returns
plain maps, never `*JSON.render/2` output):

| Field | Type | Notes |
|---|---|---|
| `categoryId` | string (uuid) | `EquipmentCategory.id`. |
| `categoryName` | string | Echo of the created name. |
| `definitions` | array of definition results | In identifying order (same sort as `Structure.list_definitions/1`: identifying first by position, then label). |
| `containers` | array of container results | Root-first, mirroring `containerPath`. Empty when no path was given. |

Definition result:

| Field | Type | Notes |
|---|---|---|
| `definitionId` | string (uuid) | `PropertyDefinition.id` — the FK later item seeds use. |
| `label` | string | |
| `valueType` | enum (as above) | |
| `required` | boolean | |
| `identifyingPosition` | integer \| null | |
| `options` | array of `{ optionId, label, position }` | Empty for non-`single_select`. Ordered by `(position, label)`. |

Container result:

| Field | Type | Notes |
|---|---|---|
| `containerId` | string (uuid) | `Container.id` — the FK later item seeds use. |
| `name` | string | |
| `parentContainerId` | string (uuid) \| null | `null` for the root. |
| `path` | string[] | Names root-first up to and including this container (echo, so callers need not reconstruct). |

Everything a later item/loan seed needs as FKs is here: exactly one
`categoryId`, one `containerId` per path level, one `definitionId` per
definition, one `optionId` per single-select option. Later contracts must
reference these ids, never names/labels.

## Out of scope for the seed (assumes valid input)

The seed creates **fresh, valid** structure. It does not exercise evolution
gates — those belong to operator API tests, not fixtures:

- **Stable identities across renames** — guaranteed structurally: the seed
  returns ids and later seeds use ids, so renames can never break references.
  The seed performs no renames itself.
- **Type-immutable-once-used** (`Structure`: `{:error, :type_immutable}`) —
  unreachable on the seed path (definitions are created once with their final
  type; the seed never updates `valueType`). No test may rely on the seed to
  produce this error.
- **Required-gate** (`{:error, :required_blocked, %{item_ids: …}}`) —
  vacuously passes: definitions are seeded **before** any items exist, so
  there are no active items to block on. A seed that wants required
  definitions with items must create the structure first, then items with
  values (the item contract's problem, not this one).
- **Retire flows** (`retire_definition/1`, `retire_option/1`,
  archive/restore containers) — not part of `seed/2`. See below for
  `delete_fixture` / `update_fixture`.

## Validation: surface vs. accept

Seeds fail fast on caller mistakes; they never paper over conflicts with
fallbacks. Concretely, the implementer maps:

**Surface (raise / return harness 422-or-409 — never silent):**

- Duplicate category name → `Categories` conflict (`:conflict`).
- Duplicate definition label within the category, duplicate
  `identifying_position`, unknown `valueType`, `options` on a non-`single_select`
  definition, missing/empty `options` on a `single_select` definition →
  changeset / `:not_single_select` errors from `Structure`.
- Duplicate option label within a definition → option changeset conflict.
- Duplicate container name under the same parent (including a second root
  with the same name) → container changeset conflict (sibling-unique rule).
- Missing `actorId` when `containerPath` is non-empty → harness arity error
  (fail fast, do not default to a system actor).
- Empty-string names/labels, over-length strings → changeset errors.

**Silently accept / normalize (documented defaults, not errors):**

- Omitted `categoryDescription` / `containerDescription` → `null`.
- Omitted `required` → `false`.
- Omitted/null `identifyingPosition` → `null` (non-identifying).
- Omitted option `position` → array index.
- Omitted `definitions` / `containerPath` → `[]` (category-only seed).
- Label casing/whitespace: passed through untouched (uniqueness checks are
  case-insensitive in the DB; the seed does not pre-normalize).

## `delete_fixture` / `update_fixture` needs

The scenario needs both, with retire-vs-delete semantics inherited from the
domain (seed teardown must not cascade):

- `delete_fixture("inventoryStructure", id)`:
  - Accepts either a **category id** or a **container id**. Containers
    carry no category FK, so a full teardown is multi-call (the wrapper
    does this; a single category-id call does not delete containers).
  - **Container id** → `Containers.delete_container/1` for that one
    container. Callers delete deepest-child first (the seed returns
    containers root→leaf; `createInventoryStructure.cleanUp` reverses
    that list). Blocked by items or remaining children
    (`:still_referenced`).
  - **Category id** → retire live options then definitions
    (`Structure.retire_option/1`, `retire_definition/1`), then
    **hard-delete** those rows iff zero `item_property_values`
    reference them (active or archived). `inventory_property_definitions.category_id`
    is `on_delete: :nothing`, so a history-free seed cannot tear the
    category down through retire-only — leftover definition rows would
    409. History-bearing definitions/options stay and surface
    `:still_referenced`. Then `Categories.delete_category/1`.
  - Wrapper order is therefore **containers deepest-first, then the
    category** (which owns option/definition teardown). That order is
    safe: containers do not FK the category. Prefer this over
    options→definitions→containers→category when calling the helper
    yourself.
  - **Blocked deletions surface, never cascade**: `:still_referenced`
    (category with items, container with items/children, definition/option
    with active values) returns a harness 409 with the blocking count where
    the domain provides it (`activeValueCount`). The fixture helper does not
    delete items on the caller's behalf — the test must delete items first.
  - Net: `delete_fixture` on a structure with item/loan history is expected
    to 409; that is the test telling you to clean up items first (or assert
    the 409 deliberately for archive-rule specs).
- `update_fixture("inventoryStructure", categoryId, attrs)`:
  - Allowed (partial attrs, same shapes as seed attrs): rename category
    (`categoryName`), rename/reorder definitions (`label`,
    `identifyingPosition`), loosen `required: true → false`, rename/reorder
    options, rename containers. Each maps to the matching domain update
    (`Categories.update_category/2`, `Structure.update_definition/2`,
    `update_option/2`, `Containers.update_container/2`).
  - **Refused, surfacing domain errors**: `valueType` change on a used
    definition → `type_immutable` (422); `required: false → true` while an
    active item lacks a valid value → `required_blocked` with `itemIds`
    (422); rename into a taken sibling/name → conflict (409). The fixture
    helper passes these through; it never migrates item values to satisfy a
    gate.
  - Moving containers (`parentContainerId` change) is **not** part of this
    fixture — moves have their own command (`Containers.move_container/2`,
    circular-parent and archived-parent rules) and belong to a later
    container-lifecycle contract if needed.

## TS side (proposed — implement when this contract is accepted)

```ts
type InventoryStructureDefinitionSeed = {
  label: string;
  valueType: "text" | "decimal" | "boolean" | "single_select";
  required?: boolean;
  identifyingPosition?: number | null;
  options?: Array<{ label: string; position?: number }>;
};

type InventoryStructureSeed = {
  attrs: {
    categoryName: string;
    categoryDescription?: string | null;
    definitions?: InventoryStructureDefinitionSeed[];
    containerPath?: string[];
    containerDescription?: string | null;
    actorId?: string;
  };
  result: {
    categoryId: string;
    categoryName: string;
    definitions: Array<{
      definitionId: string;
      label: string;
      valueType: "text" | "decimal" | "boolean" | "single_select";
      required: boolean;
      identifyingPosition: number | null;
      options: Array<{ optionId: string; label: string; position: number }>;
    }>;
    containers: Array<{
      containerId: string;
      name: string;
      parentContainerId: string | null;
      path: string[];
    }>;
  };
};

// in E2EScenarios:
type E2EScenarios = {
  // …existing…
  inventoryStructure: InventoryStructureSeed;
};
```

`E2EFixtureType` gains `"inventoryStructure"` automatically via
`Exclude<E2EScenarioName, …>`; `E2EUpdatableFixture` gains it explicitly.
`setupFunctions.ts` gets a `createInventoryStructure()` helper in the
implementing ticket (not this contract).

## Example payloads

### 1. Minimal — category + one text property + root container

Attrs:

```json
{
  "categoryName": "Longsword",
  "definitions": [
    { "label": "Blade length", "valueType": "text" }
  ],
  "containerPath": ["Cage"],
  "actorId": "11111111-1111-4111-8111-111111111111"
}
```

Result:

```json
{
  "categoryId": "22222222-2222-4222-8222-222222222222",
  "categoryName": "Longsword",
  "definitions": [
    {
      "definitionId": "33333333-3333-4333-8333-333333333333",
      "label": "Blade length",
      "valueType": "text",
      "required": false,
      "identifyingPosition": null,
      "options": []
    }
  ],
  "containers": [
    {
      "containerId": "44444444-4444-4433-8444-444444444444",
      "name": "Cage",
      "parentContainerId": null,
      "path": ["Cage"]
    }
  ]
}
```

### 2. Full — identifying properties + single-select + nested containers

Attrs:

```json
{
  "categoryName": "Feder",
  "categoryDescription": "Steel training swords",
  "definitions": [
    { "label": "Maker", "valueType": "text", "identifyingPosition": 0 },
    {
      "label": "Size",
      "valueType": "single_select",
      "required": true,
      "identifyingPosition": 1,
      "options": [{ "label": "Short" }, { "label": "Standard" }, { "label": "Long" }]
    },
    { "label": "Weight (g)", "valueType": "decimal" },
    { "label": "Club-owned", "valueType": "boolean", "required": true }
  ],
  "containerPath": ["Cage", "Rack 2"],
  "containerDescription": "Second rack from the door",
  "actorId": "11111111-1111-4111-8111-111111111111"
}
```

Result:

```json
{
  "categoryId": "55555555-5555-4555-8555-555555555555",
  "categoryName": "Feder",
  "definitions": [
    {
      "definitionId": "66666666-6666-4666-8666-666666666666",
      "label": "Maker",
      "valueType": "text",
      "required": false,
      "identifyingPosition": 0,
      "options": []
    },
    {
      "definitionId": "77777777-7777-4777-8777-777777777777",
      "label": "Size",
      "valueType": "single_select",
      "required": true,
      "identifyingPosition": 1,
      "options": [
        { "optionId": "88888888-8888-4888-8888-888888888888", "label": "Short", "position": 0 },
        { "optionId": "99999999-9999-4999-8999-999999999999", "label": "Standard", "position": 1 },
        { "optionId": "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa", "label": "Long", "position": 2 }
      ]
    },
    {
      "definitionId": "bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb",
      "label": "Weight (g)",
      "valueType": "decimal",
      "required": false,
      "identifyingPosition": null,
      "options": []
    },
    {
      "definitionId": "cccccccc-cccc-4ccc-cccc-cccccccccccc",
      "label": "Club-owned",
      "valueType": "boolean",
      "required": true,
      "identifyingPosition": null,
      "options": []
    }
  ],
  "containers": [
    {
      "containerId": "dddddddd-dddd-4ddd-dddd-dddddddddddd",
      "name": "Cage",
      "parentContainerId": null,
      "path": ["Cage"]
    },
    {
      "containerId": "eeeeeeee-eeee-4eee-eeee-eeeeeeeeeeee",
      "name": "Rack 2",
      "parentContainerId": "dddddddd-dddd-4ddd-dddd-dddddddddddd",
      "path": ["Cage", "Rack 2"]
    }
  ]
}
```

Note the `decimal` spelling: the spec shorthand "number" maps to the
`PropertyDefinition` `value_type` `"decimal"`. The seed takes `decimal` only.
