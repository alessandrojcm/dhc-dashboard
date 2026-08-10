# Atomic Session establishment and revocation

**Status:** Accepted  
**Date:** 2026-08-10

A Session implies that its Authentication Principal's Member has club access, but the previous magic-link flow inserted a Session before checking `isActive` and then deleted it from the HTTP adapter. Discord sign-in and authenticated requests expressed the same rule separately, while Membership access loss left Session rows that could become usable again after access returned.

The Authentication module owns atomic Session establishment and revocation behind a proof-oriented interface. Every login method serializes eligibility and Session insertion by locking the Member projection; unconditional Session creation is not part of the production interface. A valid magic link for an inactive Member is consumed and confirms the Authentication Principal but creates no Session. Stripe remains the source of Membership state and requests the access projection value, while the Authentication implementation applies that projection and deletes all Sessions in the same transaction when access is lost. Restored access requires a fresh sign-in.

## Considered Options

- **Mint then delete in the HTTP adapter.** Rejected because a transient ineligible Session exists and every adapter must preserve the cleanup convention.
- **Let Membership update `isActive` and separately request Session deletion.** Rejected because transaction ordering and Session persistence knowledge would leak across the seam.
- **Use a database trigger for access-loss revocation.** Rejected because it would hide the invariant from the Authentication module and its interface tests.

## Consequences

- Login and access-loss transactions contend on the same Member projection row; database serialization order determines the winner.
- If login commits first, subsequent access loss deletes the new Session. If access loss commits first, login observes inactivity and inserts nothing.
- Tests exercise the Authentication interface with real Postgres locking rather than an eligibility adapter; one Postgres implementation does not justify a new seam.
