# Beginners' Workshop Is Its Own Context With Its Own Payment Boundary

**Status:** Accepted  
**Date:** 2026-10-08  
**Tags:** beginners-workshops, workshops, waitlist, payments, stripe, boundaries, reach

## Context

The Beginners' Workshop (ALE-360) is the club's intake event between the Waitlist and Invitation. It looks like a Workshop: it has a venue, a date and time, a capacity, a fee and a Stripe payment. `Dhc.Workshops` already has a hardened payment boundary for exactly that (`PaymentCommands`, ADR 0012/0027).

Apart from about five scheduling columns, almost nothing else matches:

- **Identity.** A Registration belongs to a Member or an `ExternalUser` and stores a name and email. An Intake's person is a Waitlist registrant (UserProfile, Waitlist entry, optional Guardian) whose Intakes are anonymised on GDPR deletion (ALE-361).
- **Pricing.** A Workshop has a member price and a non-member price. A Beginners' Workshop attendee is never a Member, so it has one fee.
- **Seats.** A Workshop checks capacity when a payment completes and compensates any overflow. A Beginners' Workshop fills seats through Batches and fast-tracks, and its strict "17th sees full" rule needs a seat reservation taken before Stripe is called (ALE-364).
- **Visibility.** Workshops appear in the member calendar and the public listing, and are announced to every Member and on Discord. A Beginners' Workshop is never listed or announced, because no one can sign up for it directly.
- **Operations.** Staff scoped by assignment, Attendance Finalisation and Waitlist standing changes have no Workshop equivalent (ALE-361/362).

## Decision

**`Dhc.BeginnersWorkshops` is a new top-level context with its own tables.** It owns Beginners' Workshops, Staff, Batches, Intakes, and Intake payments and refunds. It never reads or writes `club_activities` or any `club_activity_*` table. It doesn't sit under `Dhc.Onboarding`, which stays scoped to Invitations (ADR 0013). The Invitation handoff calls Onboarding's existing issue function, and Onboarding never calls back.

**A Beginners' Workshop has one fee, an integer in cents, with no currency column.** No stored price has a currency today. The Intake payment row doesn't store currency either: Stripe's reported currency is checked against a fixed `eur`.

**An Intake references the Waitlist person and stores no copy of them.** It has no stored name or email, and there's no `ExternalUser`. Anonymisation sets the reference to null. Reporting needs states and counts, not names.

**Intake payments get their own boundary, built in the same shape as ADR 0027 but not shared with it.** It has one `execute(actor, command)`, one private lock primitive, one transition table for payment and refund status, and one `persist/1` that turns unique-index violations into domain reasons. Stripe is called only between transactions, with idempotency keys per payment and per refund. It adds a seat reservation that Workshop doesn't have. The only Stripe pieces it shares are `Dhc.Stripe.Client`/`Failure` and a new target in the `Dhc.StripeWebhooks` routing table.

**Waitlist standing changes are written in the same transaction as the Intake change.** `Dhc.Waitlist` owns the rules for which standings can change to which. It exposes a function that the Beginners' Workshop boundary calls inside its own transaction, and that boundary is the only caller that changes standing because of an Intake. Lock order: Beginners' Workshop → Waitlist entry → Intake → Carried Fee → payment → refund (the Carried Fee level was added by ALE-367; a command skips levels it doesn't need and never locks upward).

**Approved shared pieces:** `Dhc.ClubCalendar` (Dublin dates and times), `Dhc.Auth.Capabilities` (the assignment scope), `Dhc.Stripe.Client`, and the email seams (ADR 0021/0022/0028). Which email seam applies is decided on its own ticket.

**The split is enforced.** Reach forbids `Dhc.BeginnersWorkshops.* ↔ Dhc.Workshops.*` and `→ Dhc.WorkshopAnnouncements.*` in both directions, and the same applies between their web and API slices. On the frontend, an Oxlint `no-restricted-imports` override forbids importing Workshop components from Beginners' Workshop routes and back.

## Consequences

- Refund, reconciliation and the payment state machine exist twice on purpose. A bug fixed in one boundary must be checked in the other. The two boundaries share no code, so they can't drift silently in the other direction either.
- If a third payment workflow appears, extract a shared payment ledger then, with three real users, rather than now with one.
- Workshop reads (calendar, summaries, announcements, public listing) need no kind filter.

## Considered options

- **Make it a kind of Workshop (`club_activities.kind`).** Rejected: every Workshop read would need a filter, and two lifecycles and two capacity rules would share one table.
- **Own context on top of Workshop storage.** Rejected for the same reasons, with the added cost of two modules writing one table.
- **Generalise `PaymentCommands`** with a second parent and an Intake payer. Rejected: it makes the riskiest code in the app more complex for a workflow whose seat rule is the opposite (reserve before Stripe rather than compensate after).
- **Extract a shared payment ledger first.** Rejected for now: one real consumer means the shared module would have only one user.
