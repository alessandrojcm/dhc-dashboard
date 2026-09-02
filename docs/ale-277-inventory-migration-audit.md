# ALE-277: Migrated Inventory implementation audit

**Status:** completed audit; no production behavior was changed.
**Decision baseline:** [ALE-273][ale-273], [ALE-275][ale-275], [ALE-278][ale-278],
and [ALE-279][ale-279], summarized in the Inventory terms in `CONTEXT.md`.

[ale-273]: https://linear.app/alessandrojcm/issue/ALE-273
[ale-275]: https://linear.app/alessandrojcm/issue/ALE-275
[ale-278]: https://linear.app/alessandrojcm/issue/ALE-278
[ale-279]: https://linear.app/alessandrojcm/issue/ALE-279

## Scope and method

This is an implementation and schema audit, not a production-data inspection.
It traces the current Phoenix context, router, OpenAPI contract, generated SDK
exports, SvelteKit routes, migrations, and committed tests. The production
baseline migrations were marked applied rather than executed against the live
database (ADR 0001), and this worktree has no production database access.
Consequently, assertions about *possible* existing data below are schema-based
and must be measured in a read-only preflight before a migration is selected.

The target is deliberately not legacy parity. In particular, the target has one
physical Item per row, a generated immutable slug and derived label, stable
Property Definition identities, retained Maintenance Periods and Loans, archive
instead of destructive lifecycle operations for retained entities, and no
generic Item event stream.

## What is sound and worth retaining

| Area | Evidence | Audit result |
| --- | --- | --- |
| Phoenix capability seam | `apps/phoenix/lib/dhc/inventory.ex` exposes a single `Dhc.Inventory` interface while category, container, item, history, and stats implementations stay separate. Controllers call the context rather than the Repo. | **Retain.** This is a useful deep module seam for the replacement model; evolve its interface around Items, Properties, Maintenance, and Loans rather than reviving frontend service classes. |
| Phoenix ownership and generated-client path | Inventory routes live in `apps/phoenix/lib/dhc_web/router.ex`; SvelteKit calls `@dhc/api-client` through the central client options. `packages/api-client/src/index.ts` exports the generated inventory operations. | **Retain.** This realizes the Phoenix/OpenAPI/SvelteKit ownership direction and avoids direct browser table access. |
| Direct Item relationships | `inventory_items.container_id` and `category_id` are non-null foreign keys with `on_delete: :nothing` in `20260512000010_create_inventory.exs`; `Items` loads explicit category/container summaries. | **Retain as a foundation.** It matches one direct home Container and one Category, but needs lifecycle and Item-identity changes. |
| Container hierarchy safety | `Dhc.Inventory.Containers` rejects a self/descendant parent (`cycle?/2`); controller tests exercise self and descendant cycles. Reparenting naturally moves the subtree because descendants retain their parent links. | **Retain.** Add database-level protection/validation during migration because the current protection is application-only. |
| Reference guard for Categories | `Categories.delete_category/1` counts referencing Items before delete; the category foreign key also prevents accidental deletion. | **Retain and extend** to active and archived references and Property Definition dependencies. |
| Role write gate | Phoenix separates authenticated reads from `:inventory_admin_api`, granting writes to quartermaster, president, and admin. Controller tests cover the three operator roles and a member rejection. | **Retain the equal Inventory Operator capability set.** Apply the settled Loan privacy/authority rules when designing Loan reads and writes; do not introduce a different operator hierarchy. |
| Dedicated movement command | `POST /inventory/items/:id/move`, `Items.move_item/3`, and controller tests isolate a home-container change from general Item edits. | **Retain the command shape**, but make it respect reserved/checked-out Loan state and stop treating every move as permanent audit history. |
| Contract and unit/controller coverage | The spec covers categories, containers, Items, movement, maintenance, history, and stats; Phoenix controller tests cover CRUD, authorization, filters, error mapping, and command side effects. | **Salvage as characterization coverage.** It proves the old migrated contract, not the agreed target model. |

## Material gaps, contradictions, and unsafe behavior

### Inventory model and database

1. **An Item is currently a quantity-bearing record, not one physical unit.**
   The baseline schema and `Item` expose `quantity`, and `Items.item_changeset/2`
   requires a positive value. The API and SvelteKit forms display and edit it.
   There is no immutable generated slug, no derived label, and no separate
   physical-unit identity. `photo_url` is also stored and returned although the
   agreed v1 Item has no photo.

2. **Category properties are untyped, mutable JSON configuration rather than
   stable Property Definitions.** `equipment_categories.available_attributes`
   stores JSON, `attribute_schema` is explicitly unused, and Item `attributes`
   is a free-form JSON map. The Phoenix validation checks only that definitions
   are an array and their `type` is one of four strings; it does not enforce the
   requiredness, select-option membership, or typed Item-value invariants, nor
   safe in-use evolution. There are no definition/option identities or
   identifying-property ordering. A category change is accepted by `PATCH`
   without atomically validating values against the new category.

3. **Maintenance is a lossy boolean, not a retained Maintenance Period.**
   `inventory_items.out_for_maintenance` has no reason, start/end times, or
   start/end actors. It can be toggled in general Item PATCH as well as by the
   command endpoint. There is no open-period uniqueness and no interaction with
   Loans, requests, archiving, or Item movement.

4. **Loans and availability do not exist.** There is no Loan schema, migration,
   Phoenix context operation, route, OpenAPI operation, UI, Notification job, or
   test. Therefore no request/approval reservation, competing-request
   resolution, checkout/return, due-date behavior, privacy, or maintenance
   serialization can be claimed from the migrated slice. Current `Available`
   UI means only “not maintenance”, which is unsafe once Loans exist.

5. **The lifecycle is destructive and has no archive/restore semantics.**
   Items, Categories, and Containers have no archived state or restore gate.
   `Items.delete_item/1` permanently deletes an Item and the database cascades
   all `inventory_history` for it. This conflicts directly with retaining Items
   that have Maintenance or Loan history. Categories and Containers cannot
   distinguish unused entities that can be removed from historically referenced
   entities that must be archived.

6. **Container deletion violates the agreed explicit-subtree rule.**
   `containers.parent_container_id` uses `on_delete: :delete_all`, while
   `delete_container/1` checks only direct Item references. Empty descendants
   are therefore removed recursively; the committed controller test explicitly
   expects that behavior. PostgreSQL will reject deletion if a descendant is
   Item-referenced, so this is not a silent Item deletion, but it is still a
   destructive recursive operation contrary to the target and risks removing an
   empty location subtree without an explicit operator decision.

7. **Container names do not satisfy the target uniqueness rule.** The schema
   has no unique index and the changeset accepts duplicate names, including
   case-only duplicates among siblings. Cycles are checked only in application
   code, so migration preflight must also look for invalid legacy trees.

8. **Generic history is both over-retained and not safely retained.**
   `inventory_history` records create, update, move, and maintenance flag
   events, exactly the generic audit stream the target does not continue.
   Conversely, it cannot retain an Item after hard deletion, does not snapshot
   classification or values, and has none of the target Maintenance/Loan facts.
   Its `changed_by` is a stable foreign-key reference after the auth cutover,
   which is useful, but a future anonymization design must preserve/de-identify
   it rather than cascade it away.

### Phoenix/OpenAPI contract drift

1. **The spec disagrees with implementation and tests for no-op commands.**
   OpenAPI says a move to the same Container still writes a `moved` row and a
   repeated maintenance value still writes a maintenance row
   (`openapi.yaml`, item move/maintenance descriptions). `Items` writes either
   row only when state changes, and
   `inventory_items_movement_controller_test.exs` asserts no extra row. This
   must be resolved as part of removing generic history; do not preserve either
   legacy interpretation by accident.

2. **OpenAPI and stale code comments describe Supabase JWTs, while the current
   repository auth boundary is Phoenix sessions.** The inventory specification
   and several inventory comments still promise bearer JWT/`auth.users` behavior
   even though `CONTEXT.md`, router pipelines, and migration notes establish
   Phoenix session authentication and principal ownership. This is contract
   documentation drift and should be corrected when the Inventory contract is
   replaced.

3. **The old contract intentionally exposes unsafe destructive actions.**
   OpenAPI advertises DELETE Item/Container/Category without the target’s
   history-aware archive rules. It also exposes generic history to any
   authenticated Member, including actor IDs and movement information, which
   violates the agreed visibility model.

4. **Current mutations do not serialize future availability decisions.**
   Reads followed by writes use normal `Repo.get`/changesets; there is no Item
   row lock or transaction that coordinates maintenance with a request,
   approval, checkout, archive, or Container move. That is acceptable only
   because Loans do not yet exist; it is unsafe to extend piecemeal.

### SvelteKit and generated SDK

1. **The frontend is correctly generated-client based, but its model is a
   legacy compatibility adapter.** Item detail maps API DTOs back into old
   snake_case shapes (`items/[id]/+page.server.ts`) and the form schema keeps
   `quantity`, mutable JSON attributes, defaults, and the boolean maintenance
   flag. The detail UI says a Category “cannot be changed after creation” even
   though the backend accepts `categoryId` and the agreed model permits a
   validated change.

2. **The read boundary is contradictory and leaks operator-only information.**
   Phoenix permits every authenticated Member to read Categories, Containers,
   Item history, global history, and stats. The target permits Members to browse
   non-archived Items and use Category/property filters, but not standalone
   Category/Container management or operator history. Meanwhile the SvelteKit
   layout admits `member`, its Container page consequently exposes the storage
   hierarchy, while Item list/detail and Category page server loads demand an
   operator role. Thus normal Members are inconsistently blocked from intended
   item browsing yet allowed to view the wrong storage-management surface.

3. **UI promises behavior the backend does not have.** The Container delete
   confirmation says child Containers will be deleted and Items moved to the
   parent/root. The backend does not move Items; it either deletes empty
   descendants or fails on a reference. The Item delete operation exists in
   Phoenix/OpenAPI and is exported by the SDK, but no Item remote form/UI exposes
   it. These inconsistencies make the current flow unsuitable as a migration
   target.

4. **The SDK is mechanically complete for the legacy contract, not the target.**
   `packages/api-client/src/index.ts` exports all migrated Inventory operations,
   including delete/move/maintenance. It has no operations or model types for
   slugs, archival, definitions/options, periods, availability reasons, Loans,
   queues, or notifications because the OpenAPI contract has none.

### Tests

Phoenix tests are valuable characterization tests for the implemented legacy
REST behavior, including role gates, list filters, cycle prevention, category
reference deletion, and history side effects. They do **not** cover target
invariants: one unit/slug, property-definition validation/evolution, archived
dependencies, retained maintenance periods, Loan lifecycle/concurrency/privacy,
or Member-facing browsing rules. The controller tests also intentionally lock
in the undesirable recursive Container deletion and the no-op history behavior;
they should be retained only until replacement characterization/target tests are
written.

The browser test situation is weaker: all four committed Inventory suites
(`inventory-categories.spec.ts`, `inventory-containers.spec.ts`,
`inventory-items.spec.ts`, and `inventory-full-lifecycle.spec.ts`) wrap their
suites in `test.describe.skip`. They additionally construct the obsolete
quantity/name-in-attributes model. They are not execution evidence for the
migrated UI.

## Existing-data assumptions for ALE-272 and later migrations

Do not infer production contents from test fixtures or from the seven default
categories in the baseline migration. Baselines are documentation/fresh-schema
builders and were marked applied in production. There is no committed evidence
of live Item count, Container tree, photos, JSON shapes, or history volume.

Before any destructive or contract-changing migration, take a read-only,
versioned inventory profile and record at least:

1. row counts and IDs for Categories, Containers, Items, and history; null or
   orphaned actor references; and the oldest/newest rows;
2. all `quantity > 1` Items. Each is a bulk record that must become distinct
   physical units before it can participate in a Loan; a later decision must
   define how many slugs are minted and whether legacy notes/attributes/history
   are copied or attached only as provenance;
3. `photo_url` presence and storage ownership before removing the field;
4. all distinct `attributes` keys and JSON types, null/empty values, values not
   represented by their Category’s current `available_attributes`, duplicate or
   renamed-looking definition names, and select values outside current options;
5. Categories with malformed/duplicate/case-colliding definition labels or
   option labels, and the relationship between the unused `attribute_schema`
   column and live configuration;
6. duplicate/case-colliding sibling Container names, root names, missing parents,
   and cycles; plus parent Containers whose descendant subtree would be affected
   by the current cascade;
7. Items marked `out_for_maintenance`, existing history action counts, missing
   `changed_by`, and history rows that refer to old/new Containers. A boolean
   supplies no maintenance reason/start actor, so a migration cannot truthfully
   reconstruct a retained period; it must create an explicitly marked imported
   open period or obtain operator reconciliation;
8. Items with history. Preserve existing generic rows cheaply where possible as
   legacy evidence, but do not fabricate missing events and do not allow the new
   model to cascade-delete them. No existing data establishes Loan history,
   because Loans have not been implemented;
9. application writes or integrations still using the Inventory endpoints, so
   expand/dual-read/contract timing does not break operators mid-migration.

The data profile is a hard input to the delivery strategy, not a prerequisite to
this audit. It determines whether quantity expansion, property-value mapping,
maintenance reconciliation, and Container cleanup are routine backfills or a
coordinated maintenance-window migration. New Ecto migrations must follow the
repository expand/contract deploy shape; never rerun the baseline inventory
migration on production.

## Recommended disposition for delivery planning

Keep the Phoenix ownership path, `Dhc.Inventory` seam, direct Category/Container
foreign keys, cycle-detection intent, generated SDK pipeline, and old tests as
characterization evidence. Replace rather than layer on the quantity Item,
free-form property JSON, maintenance boolean, generic history stream, cascade
Container lifecycle, and legacy member-facing pages. Build the target through
additive schemas and target interfaces first, profile and backfill live data,
then cut over reads/writes and remove legacy fields/actions only after retained
history and active dependencies are safe.
