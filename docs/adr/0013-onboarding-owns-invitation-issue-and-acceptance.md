# Onboarding owns Invitation issue and Invitation Acceptance

**Status:** Accepted  
**Date:** 2026-08-10  
**Amends:** ADR-0010  
**Amended by:** ADR-0014

Invitation issue, pricing, Stripe progression, Waitlist transitions, and Invitation Acceptance were distributed across Invitation modules, workers, and repositories. Pricing created durable Stripe customer state before acceptance, and Stripe work inside the conversion transaction could survive a local rollback without a durable record of what happened. ADR-0010 fixed the atomic birth of the Authentication Principal and Member but deferred payment idempotency.

One deep Onboarding module owns coordination through a public interface for Invitation issue, verification, read-only pricing, and Invitation Acceptance. Internal modules own batch finalization, recovery, and persistence. Per-Invitation issue atomically records the Invitation, Waitlist transition, and email job; failure in later batch finalization never replays completed issue work. Pricing creates no Stripe customer and changes no Invitation state.

Invitation Acceptance creates or resumes one active Invitation Acceptance Attempt before any Stripe mutation. The Attempt records external progress independently and survives conversion rollback; retries reuse it and its stable idempotency keys. A declined Attempt must close before another begins. Stripe residual state is acceptable because it is observable and reconcilable through the Attempt. The final conversion still creates the Authentication Principal, Member records, Role, Membership, accepted Invitation, and joined Waitlist atomically, and it never establishes a Session. ADR-0014 adds the invitation-bound Discord verification continuation and requires the Discord External Identity to join that same final transaction.

Pricing and acceptance share one internal Stripe seam with production and test adapters. Waitlist, Authentication, Membership, Postgres, and Oban remain concrete implementation dependencies rather than hypothetical seams.

## Considered Options

- **Keep Invitation as the coordination module.** Rejected because issue and acceptance are the conversion side of Onboarding and their invariants would remain distributed.
- **Expose acceptance phases such as start, provision, and finalize.** Rejected because callers would own ordering, retry, and replay rules, producing a shallow interface.
- **Create a Stripe customer during pricing.** Rejected because a read would create abandoned external state and race Invitation Acceptance.
- **Identify attempts with caller-generated request IDs.** Rejected because the Invitation already provides stable identity; at most one active Attempt is allowed per Invitation.

## Consequences

- Invitation Acceptance becomes a durable multi-transaction workflow around an atomic Principal-and-Member conversion.
- Every accepted Invitation creates Membership. Complimentary membership is represented by the existing 100% discount mechanism rather than a second acceptance path.
- ADR-0010's deferred payment-idempotency concern is resolved by Invitation Acceptance Attempts rather than cleanup or cross-system atomicity.
