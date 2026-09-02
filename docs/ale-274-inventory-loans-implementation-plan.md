# ALE-274 — Inventory and Loans implementation plan

**Status:** authoritative implementation index; no production behavior is
changed by this document.

## Purpose and precedence

This is the implementation entry point for the Inventory and Loan replacement.
It synthesizes the resolved requirements into target outcomes, change
boundaries, delivery order, and release gates without repeating the detailed
decision records. Implementation tickets must link here, [parent map
ALE-271][ale-271], and the applicable source decision below.

This index does not create a general ordering among its sources. Each source
controls its stated subject; where decisions genuinely conflict, follow the
source that expressly resolves that conflict. The current explicit exception is
that [ALE-279][ale-279] supersedes [ALE-275][ale-275] on editable approved and
checked-out Loan due dates. The linked sources are:

- [ALE-273][ale-273] — Loan lifecycle and allocation;
- [ALE-275][ale-275] — access and notification boundaries;
- [ALE-278][ale-278] — Inventory structure and property evolution;
- [ALE-279][ale-279] — retention and due-date correction;
- [ALE-276][ale-276] — selected mobile workflows; and
- [ALE-272][ale-272] — migration, deployment, compatibility, and verification,
  informed by the [ALE-277 audit][ale-277].

`CONTEXT.md` controls domain terminology, while
[`docs/agents/migration-notes.md`](agents/migration-notes.md) records durable
repository migration conventions. In particular, use the glossary definitions
of **Item**, **Container**, **Category**, **Property Definition**,
**Maintenance Period**, **Loan**, **Item Label**, and **Retention Policy**.

[ale-272]: ale-272-inventory-migration-delivery-strategy.md
[ale-276]: ale-276-mobile-inventory-and-loan-workflow-prototype.md
[ale-277]: ale-277-inventory-migration-audit.md
[ale-271]: https://linear.app/alessandrojcm/issue/ALE-271
[ale-273]: https://linear.app/alessandrojcm/issue/ALE-273
[ale-275]: https://linear.app/alessandrojcm/issue/ALE-275
[ale-278]: https://linear.app/alessandrojcm/issue/ALE-278
[ale-279]: https://linear.app/alessandrojcm/issue/ALE-279

## Target capability

Deliver one Phoenix-owned Inventory capability, exposed by the generated
OpenAPI client, that supports:

- Member-safe Item browse, search, filter, slug deep-link, request, and own
  Loan history;
- Inventory Operator structure and Item administration, retained Maintenance,
  and a shared action-led Loan queue; and
- Item labels (slug plus QR deep-link) and an optional QR scan entry that
  selects the ordinary Item route and never bypasses authorization or commands.

Following [ALE-272][ale-272], `Dhc.Inventory` is the public deep module seam
for controllers and workers. Its callers use viewer-shaped projections and
domain commands; its implementation owns locking, typed value storage,
availability, transition interlocks, and reminder scheduling. Keep one
`Inventory` OpenAPI tag and `/api/inventory` root. Phoenix cookie sessions and
generated `@dhc/api-client` calls remain the only application access path.

The target does not seek legacy parity. Availability is a projection of an
Item's active state, not a stored flag or a borrower disclosure. A direct
Container is an Item's assigned home location, not live custody. Loan and
Maintenance records are retained facts; routine Inventory edits are not a
generic audit stream.

## Change boundary

| Area | Retain | Correct or replace | Build in the target |
| --- | --- | --- | --- |
| Ownership and seam | Phoenix ownership, `Dhc.Inventory`, generated OpenAPI/client path | Reshape CRUD-oriented interfaces around viewer intent and domain commands | Catalog, Structure, Items, Maintenance, Loans, and Reminders internals behind the one public seam |
| Item and structure | Direct Item Category/Container links; dedicated movement command; application cycle feedback | Quantity-bearing records, photos, JSON properties, and unsafe Container cascades | One slugged physical Item, derived label, typed Definition/Option/Value model, archive/restore, DB-backed hierarchy guards |
| Availability and history | Existing tests as temporary characterization; useful legacy history rows where cheap to preserve | Boolean Maintenance and generic history writes; destructive Item/history lifecycle | Retained Maintenance Periods, retained Loan records and history-safe Item snapshots; no new generic Item events |
| Access and UI | Equal quartermaster/president/admin Inventory Operator authority | Member-visible Container/history management and legacy management UI | Mobile-first Member catalog/request/history; operator structure, Item actions, and shared Loan queue |
| Notifications | `Dhc.Notifications.create/2` as the sole creation seam and post-commit broadcast rule | Non-idempotent reminder delivery or a second notification write path | Keyed Notification extension, durable reminder ledger, and scheduled reconciliation |

The exact invariants, transition rules, fields, privacy projections, reminder
matrix, schema shapes, and legacy-data transformations belong to the linked
source decisions. Do not recreate them in child tickets; cite the controlling
source and test its acceptance examples instead.

## Required implementation boundaries

1. **Item and property model.** One Item is one physical unit with immutable
   slug and derived label. Categories, Definitions, Options, and typed values
   evolve under their stable identities and retained references. Archive rather
   than hard-delete any entity with retained history. Follow [ALE-278][ale-278]
   for the complete structure and evolution rules.
2. **Availability-changing commands.** Requests, approvals, cancellations,
   checkout, return, due-date edits, Maintenance, archive/restore/delete, and
   blocked moves serialize on the Item in one outer transaction. Constraints
   are the backstop; races return a domain `409`, not a server error. Follow
   [ALE-273][ale-273] for lifecycle/allocation and [ALE-272][ale-272] for the
   interlock matrix.
3. **Visibility.** Member catalog responses never reveal Containers, borrowers,
   another Member's Loans, or operator Maintenance facts. A borrower receives
   the entitled Container path only in the approved Loan flow. Operators receive
   operational projections. Follow [ALE-275][ale-275].
4. **Retention.** Preserve every Loan and every Maintenance Period with their
   recorded operators; preserve legacy generic history read-only where safe but
   never extend or fabricate it. Member anonymization remains deferred behind
   stable Principal references. Follow [ALE-279][ale-279].
5. **Mobile workflows.** Make physical work Item-led and present only legal next
   actions. Use the selected browse/request, shared queue, and label/scan
   journeys from [ALE-276][ale-276]; do not make scan a separate authorization,
   identifier, or command surface.

## Delivery sequence and dependencies

Use the **expand → target-code → cutover → contract** strategy from
[ALE-272][ale-272]. Do not dual-write or translate target commands into legacy
quantity/JSON semantics.

| Stage | Implementable work | Depends on | Exit gate |
| --- | --- | --- | --- |
| 0. Prepare | Characterization only where it protects a touched legacy path; profile, mapping, and repeat-safe backfill tooling; restored-backup rehearsal | Read-only backup/production access and frozen unrelated Inventory changes | Aggregate profile is complete; anomalies are either absent or have approved mapping dispositions; rehearsal proves source/target reconciliation |
| 1. Expand | Add target tables, constraints, restrictive FKs, target read support, migration tooling, and independently controlled server-side flags for target catalog reads, commands, and label/scan UI | Stage 0 | Additive migrations deploy cleanly; no target command is exposed; each target surface can be stopped without restoring legacy writes; profile/backfill rehearsal remains reproducible |
| 2a. Structure | Operator Category, Definition/Option, and Container target interfaces | Stage 1 | Typed-property and hierarchy/dependency invariants pass through public interfaces and DB backstops |
| 2b. Items and Maintenance | Operator Item lifecycle, labels, movement interlocks, and retained Maintenance | Stage 2a | Archive/delete and Maintenance interlocks pass; legacy generic writes are not used by target paths |
| 2c. Member catalog | Catalog/search and availability projections; label printing | Stages 2a–2b | Member privacy and mobile browse scenarios pass with generated-client types |
| 2d. Loan operations | Member request/cancel/history, operator queue and lifecycle commands, Notification idempotency prerequisite, and reminders | Stage 2c and the amended Notification migration specification | Lifecycle, allocation, privacy, transition-notification retry, reminder retry, and due-date supersession tests pass |
| 2e. Scan convenience | Browser QR adapter with typed-slug/search fallback | Stages 2c–2d; labels/slug lookup | Scan reaches the normal authorized Item route; denial or failure has no workflow impact |
| 3. Cut over | Freeze writes, take verified backup and final profile, run approved backfill, disable legacy mutations, deploy paired target API/UI, and enable target commands | All required Stage 2 slices and a successful production rehearsal | All reconciliation and smoke checks pass while maintenance mode remains enabled |
| 4. Contract | Remove legacy callers/routes/spec/client/UI/tests and obsolete columns after observation | Zero legacy traffic for the agreed observation period | Legacy endpoint telemetry is zero; retained history and target constraints are verified before each destructive removal |

The production-profile/remapping decision is a hard prerequisite only for the
implementing migration ticket, not for planning. The keyed Notification schema
and API change is a hard prerequisite for every exposed Loan command and
reminder; amend the owning Notification specification before that slice starts.

## Implementation-ticket acceptance gates

Every child ticket must name its stage, controlling decision links, migration
shape, and the gates it owns. It is not complete merely because its local UI or
endpoint works.

- **Schema/data gate:** additive work is reversible until target writes; any
  backfill is deterministic, provenance-backed, count-reconciled, and fails
  closed. Contract work has a verified restore path rather than a production
  rollback.
- **Domain gate:** cover the source decision's invariants through public
  `Dhc.Inventory` interfaces, plus direct SQL only for constraints unavailable
  at that seam. Include concurrency where the slice changes availability.
- **Contract gate:** specify target viewer-shaped schemas and command-specific
  requests in OpenAPI; regenerate and expose both sides according to the
  [API Contract and API Client workflow](agents/commands.md#api-contract-full-pipeline).
  No generated file is edited manually.
- **Privacy/authorization gate:** prove Member, own-Loan, and Operator views
  separately, including the absence of borrower, Container, and Maintenance
  leakage.
- **Migration/cutover gate:** use aggregate-only telemetry and artifacts; no
  unreviewed similarity mapping, fabricated historical facts, or continuing
  legacy mutation during compatibility.
- **Release gate:** before reopening Inventory traffic, verify the independent
  target-surface flags and pass the target schema and backfill checks,
  Item/slug/label flow, Member browse/request/cancel, operator
  approval/checkout/return/Maintenance/archive interlocks, auth responses, and
  idempotent due-date/reminder reconciliation. A mismatch, privacy breach,
  duplicate reminder, or smoke failure is a no-go.

## Explicitly deferred or excluded

Do not add bulk consumables, fines, renewals, waitlists, recurring Loans,
member-recorded returns, property defaults or advanced property types, email
notifications, barcode hardware/schema, or general reporting/export. Camera
scan is optional convenience after the correct slug-based flows. Utilization,
member borrowing analytics, stock audits, and custom reports wait for real Loan
volume.

## Residual implementation risk

Live Inventory shape, external legacy writers, quantity expansion, malformed
property data, maintenance-flag reconciliation, legacy actor links, and photo
storage ownership remain unknown until Stage 0 evidence exists. Treat the
profile and restored-backup rehearsal as the decision point for routine versus
operator-reconciled cutover, preserve legacy evidence until its disposition is
proven, and use the [ALE-272][ale-272] restore-and-old-release recovery path if
the cutover gate fails.
