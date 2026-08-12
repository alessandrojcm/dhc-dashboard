# Durable Workshop Payment Attempts and Refunds

**Status:** Accepted  
**Date:** 2026-08-10

Workshop payment, Registration, compensation, cancellation, and Refund progression were interleaved in one implementation. Callers could supply a Member payment amount, valid payments could fail to produce either a Registration or a durable Refund, and Workshop cancellation reported success after discarding synchronous Refund failures.

The Workshop interface remains caller-shaped, while internal Registration and Refund modules own the workflows behind that seam. A Workshop's price is authoritative. Every payment begins as a durable Payment Attempt, and every valid paid Payment Attempt concludes exactly once with either a Registration or a compensating Refund. Invalid or mismatched payment identity remains a policy failure and is not automatically refunded.

Creating a Refund records a durable repayment obligation and one unique Oban job in the same transaction; it does not mean Stripe has completed repayment. Workshop cancellation succeeds after every required Refund is durable. Each Refund progresses independently with a stable Stripe idempotency key, retries transport and provider failures, stops for validation or policy intervention, and reaches terminal state through Stripe events or reconciliation. Stripe has production and test adapters at a real internal seam; Postgres and Oban use their concrete test implementations.

## Considered Options

- **Keep synchronous Stripe repayment inside Registration and cancellation transactions.** Rejected because remote failure can strand valid payments or partially process Workshop cancellation.
- **Attach compensation directly to provider identifiers without a Payment Attempt.** Rejected because initiation, replay, Registration, and compensation need one durable identity.
- **Expose Registration and Refund as new public modules.** Rejected because forwarding interfaces would be shallow; callers continue to use the Workshop interface.
- **Use one job for all Workshop Refunds.** Rejected because one Refund per job gives independent retry, idempotency, observability, and terminal state.

## Consequences

- Refund persistence must represent both a retained Registration and a paid Payment Attempt that produced no Registration.
- HTTP responses distinguish a durable compensation obligation from successful Registration without exposing Stripe progression.
- Existing synchronous Refund tests move to the Workshop interface and assert durable outcomes, worker retry, event progression, and reconciliation.
