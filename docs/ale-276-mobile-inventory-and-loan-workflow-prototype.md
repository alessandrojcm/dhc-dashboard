# ALE-276 — Mobile inventory and Loan workflow prototype

## Verdict

The first release should use a **member browse-and-request journey** plus an
**operator action queue**. Physical actions (handover, return, movement, and
maintenance) begin by identifying one Item, then present only valid actions for
its current state. This makes the operational work possible on a phone without
turning the member browse experience into a quartermaster console.

The interactive, intentionally throwaway artifact is the authenticated Svelte
route:

```
/dashboard/inventory/prototype/mobile-workflows?variant=member
/dashboard/inventory/prototype/mobile-workflows?variant=queue
/dashboard/inventory/prototype/mobile-workflows?variant=scan
```

It uses local sample state only. In development, the floating control can also
be operated with the left/right arrow keys outside form controls. The switcher
is compiled out of production builds.

## Journeys selected

### Member: browse, decide, request, then collect

1. Browse non-archived Items through free-text search and Category/property
   filters. Show the derived Item label, Category, identifying properties, and
   an availability badge with a non-personal reason when unavailable.
2. Open one Item and submit `startsOn`, `dueOn`, and an optional note in the
   same mobile-sized request sheet. The request creates no entitlement.
3. On approval, the notification and the Member’s Loan detail reveal the
   approved dates and the Item's home Container path. The Member brings that
   information to collection; an Inventory Operator records actual checkout.
4. The Member’s Loan history is the place to cancel a requested or approved
   Loan before checkout and to see rejected/cancelled records. It is not mixed
   into general inventory browsing.

### Inventory Operator: one shared, action-led queue

1. Open a shared queue grouped as **requests**, **ready for handover**,
   **returns due today**, and **overdue**. Counts are operational triage, not
   ownership assignment; every Inventory Operator has equal authority.
2. A request card has Member, Item, requested dates/note, and the single next
   decision: approve or reject. Approval collects the final dates/note and
   atomically reserves the Item and rejects competing requests.
3. A ready-to-handover card shows the Item label/slug and Container path.
   After the operator checks the physical Item, the one primary action records
   checkout. A checked-out or overdue card similarly offers return. This keeps
   the retained Loan lifecycle visible without exposing invalid transitions.
4. Item movement and Maintenance are Item-led rather than Loan-queue actions.
   After identifying the Item, an operator can move it (except when reserved or
   checked out), start Maintenance with a reason, or end Maintenance with an
   optional note. The backend remains the concurrency authority.

## Labels and scanning

**Adopt physical Item labels in the first release.** Every label shows the
immutable, human-readable Item slug in plain text and a QR code that resolves
to the Item by slug. The system-generated slug is already the stable physical
identity; a label does not introduce a second identifier.

**Adopt QR scan entry as an operator convenience, not as a prerequisite.** A
scan must resolve to the same authenticated Item detail/action route as a typed
slug or ordinary search. Camera denial, poor connectivity, damaged labels, and
manual collection all retain the human-readable slug fallback. Do not add a
separate barcode representation or scanner-only API in v1. QR is preferable to
linear barcodes because the label can encode/deep-link the Item URL while the
slug remains visible and manually searchable.

The scan result must not bypass authorization or state validation. It only
selects an Item; the normal command endpoint determines whether checkout,
return, move, or Maintenance is legal.

## Search, queue, and reporting scope

First release search needs a server-side Item lookup over derived label,
immutable slug, Category, and property values, with Category/property,
availability, and archive filters. Members never receive Container as a browse
filter; operators may use Container as a location filter.

First release needs a dedicated operator Loan queue query filtered by lifecycle
bucket (`requested`, `approved`, `checked_out`, derived `overdue`) and due date,
plus small counts for requests, handovers, due/overdue returns, and open
Maintenance. These are operational views, not a general reporting system.

Defer utilization trends, member borrowing reports, export, stock audits, and
custom report builders until the club has real Loan volume. The selected queue
and retained Loan/Maintenance records preserve the facts needed to add them
without a new workflow model.

## Implementation consequences

- Add a Member-facing inventory browse/detail/request capability distinct from
  Inventory Operator Category/Container management.
- Add Loan list/detail and queue contracts alongside the lifecycle decisions in
  ALE-273; return Item labels, slug, derived availability, and the Container
  path only where the viewer is entitled to see it.
- Add a slug lookup/deep link that the QR code can target, a label-printing
  surface, and an optional browser scanner adapter owned by the web UI. No
  scanner package, hardware integration, or barcode schema is chosen by this
  prototype.
- Ensure queue counters and search are projections/queries only; approvals,
  checkouts, returns, moves, and Maintenance remain atomic Phoenix commands.

## Scenarios checked

- A Member sees an Item on loan but cannot infer the borrower and cannot submit
  a request.
- Two Members request the same available Item. The operator approves one; the
  other ordinary request is rejected, and the queue no longer offers it.
- A QR label is scanned at the rack while the Item has an approved Loan: the
  action screen offers checkout, not movement or Maintenance.
- An Item returns with a fault: record return first, then start Maintenance
  with its reason. There is no return-condition subdomain in v1.
- A label is damaged or a camera is unavailable: search the printed slug and
  perform the same action path.
