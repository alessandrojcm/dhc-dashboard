# Workshop Payment Commands Share One Lock Order

**Status:** Accepted  
**Date:** 2026-10-06  
**Tags:** workshops, payments, refunds, concurrency, locking, ecto, stripe

## Context

ADR 0012 made every Workshop payment a durable Payment Attempt that concludes exactly once with a Registration or a compensating Refund, and said internal Registration and Refund modules would own those workflows behind the caller-shaped `Dhc.Workshops` interface. Those internal modules were never extracted. The workflows live as private functions in `Dhc.Workshops`, with Refund progression split across `Dhc.Workshops.Refund` (a schema module that also applies Stripe refund events), `RefundWorker`, and `RefundReconciliationWorker`.

Each workflow wrote its own transaction, and they disagree:

- Member completion locks Workshop then Payment Attempt in one transaction and Payment Attempt then Workshop in the next; external completion locks Payment Attempt then Workshop. Two completions can deadlock.
- `cancel_workshop` creates cancellation Refunds without locking the Registrations, while `process_refund` locks only the Registration. Both check for an existing Refund and then `insert!`; the unique index catches the duplicate as an uncaught constraint error (HTTP 500).
- The amount/currency mismatch writes `policy_failed` outside any transaction; member cancellation and refund eligibility are decided on unlocked reads.
- Refund status is written in four places, Payment Attempt `refunded` in two, and Refund rows are constructed in three.

## Decision

`Dhc.Workshops.PaymentCommands.execute(actor, command)` is the **only** implementation of a transaction that starts, concludes, cancels, or refunds a Workshop payment. Its scope is: starting a member or external Payment Attempt, member and external completion (Registration or compensating Refund), member cancellation, requested Refunds, the Refund fan-out of Workshop cancellation, Refund submission, Stripe refund events, and refund reconciliation. Workshop CRUD, publish, interest, attendance, and read models stay in `Dhc.Workshops`.

It owns, exactly once:

- one private locking primitive with the order **Workshop → Payment Attempt → Registration → Refund**. A command may skip levels but never lock upward. Commands that begin from a Refund peek it unlocked only to learn which rows to lock, then re-read it under the lock and retry from a fresh peek if it moved; refund-only progression does not take the Workshop lock;
- no Stripe call inside a transaction: Stripe runs between transactions, and its result is written only through the locking primitive after an authoritative re-read. Duplicate provider side effects are prevented by the existing per-attempt and per-Refund idempotency keys; no lease is introduced;
- one transition table for Payment Attempt status (`pending → paid → registered | compensating → refunded`, `policy_failed`) and Refund status (`pending → processing → completed | failed | cancelled`). Every status write goes through it; terminal Refunds are immutable;
- one write path, `persist/1`, that declares the unique indexes on every changeset and translates violations into reasons the public functions already use (`:already_requested`, `:already_registered`) — no bang inserts;
- refund eligibility as pure predicates shared by the advisory `refund_eligibility/1` read and the locked command, so the advisory answer can be stale but never computed by a different rule.

`Dhc.Workshops` keeps its public functions as the compatibility seam and delegates each command to `execute/2`. The refund workers become argument-to-command drivers; `Dhc.Workshops.Refund` returns to being a schema; Stripe refund events reach the boundary through a public `Dhc.Workshops` function rather than the schema module.

A Registration still becomes `refunded` when its Refund obligation is recorded; Stripe progress is a fact of the Refund.

## Consequences

- A new payment or refund rule is added once, as a command clause under the existing primitive, never as a new `Repo.transaction` in `Dhc.Workshops`.
- Lock-order and race coverage run against real concurrent connections outside the SQL sandbox, because sandboxed tests cannot reproduce lock-order bugs. The existing `Dhc.Workshops`-level suites remain unchanged as the regression net.
- The Stripe adapter is still selected through application configuration; replacing that seam is a separate decision.
- `cancel_workshop` may now return `:already_requested` when it races a requested Refund instead of crashing.

## Considered options

- **Pure refactor preserving current behavior.** Rejected: the lock order and constraint translation are the reason for the boundary; moving the defects inside it would only relocate them.
- **Named internal functions sharing private helpers.** Rejected for the same reason as in ADR 0023: it removes duplicated code but not duplicated responsibility, and each function could still order locks differently.
- **A lease/fence like Invitation Acceptance `progress/2`.** Rejected: concurrent callers for one attempt perform the same idempotent Stripe work, so authoritative re-read under lock is sufficient.
- **A separate interim Registration status until Stripe repays.** Deferred: a domain change with migration and frontend impact, independent of the transaction boundary.
