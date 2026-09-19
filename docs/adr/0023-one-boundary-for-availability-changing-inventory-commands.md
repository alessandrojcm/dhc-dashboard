# One Transaction Boundary for Availability-Changing Inventory Commands

**Status:** Accepted  
**Date:** 2026-09-16  
**Amended:** 2026-09-18 — container-chain `FOR SHARE` (root first) precedes the item `FOR UPDATE`; restore retries from a peek when the container moved  
**Tags:** inventory, loans, concurrency, locking, ecto

## Context

Inventory commands that change an item's availability were spread across `Dhc.Inventory.OperatorItemLifecycle` (move, maintenance, archive, restore), `Dhc.Inventory.OperatorLoans` (approve, reject, cancel, checkout, return, date edits), and `Dhc.Inventory.MemberLoans` (request, cancel). Each module owned different user-facing operations but re-implemented the same transaction protocol: resolve the item, lock the item `FOR UPDATE` before any loan row, re-read under the lock, derive availability from maintenance and active-loan facts, validate, write through changesets with constraint translation, project for the caller.

The item-before-loan lock order is load-bearing — the reverse order deadlocks a member cancellation against an approval — and it was documented and reimplemented in several private functions. Correctness depended on each new command reproducing the protocol. The operator queue also computed advisory readiness (`ready_for_checkout?`) with its own copy of the window and blocking rules the checkout command applied under the lock (GH-508).

## Decision

`Dhc.Inventory.AvailabilityCommands.execute(actor, command)` is the **only** implementation of an availability-changing transaction. It owns, exactly once:

- one private locking primitive, `with_locked_item/2`, that takes the item `FOR UPDATE` first and, for loan commands, reads the loan's `item_id` **unlocked** purely to discover which item to lock, then re-reads the loan `FOR UPDATE` under the item lock — nothing is decided from the unlocked row;
- availability derivation through `ItemProjection` under that lock (no stored flag);
- input normalization (dates, optional text, attribute keys), the club-calendar date and window policy, and lifecycle eligibility;
- one write path, `persist/1`, that declares the partial unique indexes and principal foreign keys on every changeset and translates each into a stable domain reason (`:already_allocated`, `:duplicate_request`, `:maintenance_open`, `:unknown_actor`) — no bang calls;
- transaction rollback and result normalization;
- actor-appropriate projection: `{:loan, member_view | operator_view}` or `{:item, projected_item}`.

### 2026-09-18 lock-order amendment

The accepted decision above still describes the original item-before-loan protocol. Commands that depend on a container now lock that container chain `FOR SHARE` **before** the item `FOR UPDATE` (root first): a move locks the destination chain first; a restore locks the item's current chain first. That matches container archive, which locks the container (and its subtree) before any item row. After the item lock come the dependent rows (the loan, the open maintenance period, the item's live loans). A restore peeks the item only to learn which chain to share-lock; if the locked row sits in a different container, the transaction rolls back and retries from a fresh peek rather than locking a new chain while holding the item. The item-before-loan rule in the original decision remains; the container chain is an earlier step in the same protocol.

Role authorization is explicit in the actor value (`{:operator, id}`, `{:member, id}`, `:system`); the wrong actor is `{:error, :forbidden}` before any read.

Two small modules are extracted so reads and commands share one rule: `Dhc.Inventory.LoanPolicy` (pure predicates — `within_window?`, `overdue?`, `handover_blocked?`, `ordered?`, …) and `Dhc.Inventory.LoanProjection` (`operator_view/2`, `member_view/2`). The queue's advisory `ready_for_checkout?` and the command's checkout gate evaluate the same `LoanPolicy` functions, so the advisory value can be stale but never computed by a different rule.

`OperatorItemLifecycle`, `OperatorLoans`, and `MemberLoans` remain as **facades**: unchanged public signatures and return shapes, each command a single `execute/2` call plus outcome unwrapping. Reads (`get_operator_loan/1`, own history, period listing) and the non-transition `delete_operator_item/2` stay where they were. `Dhc.Inventory` and the controllers are untouched.

Notifications stay outside the boundary: every transition is a durable row, and the HTTP exposure attaches keyed notifications after the command returns (`Dhc.Inventory.notify_loan_transition/2`).

## Consequences

- Adding a rule to a command means adding it in one place, where the member and item commands share it; adding a new availability-changing command means adding one `run/4` clause under the existing primitive, not a new transaction wrapper.
- Concurrency, lock order, and database-backstop coverage live once in `Dhc.Inventory.AvailabilityCommandsTest`; the facade tests keep only their role contract.
- The restore command's value errors reach the boundary as `{:error, {:invalid_values, errors}}`; `OperatorItemLifecycle` translates that to its existing three-tuple at the edge.
- `:system` is reserved in the actor type and authorizes nothing yet; a first system-driven transition must add it to the authorization table deliberately.
- A future caller may call `execute/2` directly and receive tagged outcomes; the facades are the compatibility layer while that migration is optional.

## Considered options

- **A generic repository or state-machine framework.** Rejected: the abstraction worth having is the *availability-changing transaction protocol* — the lock order, the re-read, the constraint translation — not persistence in general. Ecto/PostgreSQL locking and constraints are part of the contract and are tested through the SQL sandbox, not replaced.
- **Shared private helpers imported into the three modules.** Rejected: it removes duplication of code but not of responsibility; each module would still own a transaction wrapper and could still call the helpers in the wrong order.
- **Deleting the facades and pointing `Dhc.Inventory` at the boundary.** Deferred: the facades cost little, keep the context's return shapes stable for controllers and the E2E harness, and can be removed once callers adopt tagged outcomes.
