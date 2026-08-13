# ADR 0010: Authentication within Invitation Acceptance

**Status:** Accepted
**Amended by:** ADR-0013, ADR-0014
**Date:** 2026-07-17
**Deciders:** @alessandrojcm
**Tags:** authentication, phoenix, invitations, onboarding, migration

## Context

ADR 0009 fixed that Phoenix owns authentication (principals, identities, sessions) via `phx.gen.auth` plus Assent for Discord. It left open *how* authentication integrates with Invitation Acceptance — the atomic conversion event that turns a prospective member into a Member. The wayfinder ticket ALE-151 ("Define authentication within Invitation Acceptance") was opened to resolve that.

Today's acceptance flow is shaped by Supabase limitations, not by the domain. At invitation **issue** time, a worker calls the Supabase admin API to create a GoTrue `auth.users` row, and `upsert_invited_profile` creates a `UserProfile` keyed by that Supabase UUID — so an auth identity and a profile row exist for a *prospective* member who has not yet accepted and may never. Acceptance (`Dhc.Invitations.accept/5`) then only materializes a `MemberProfile` on top of the already-existing identity, inside a `Repo.transaction` that locks the invitation `FOR UPDATE`, runs Stripe payment, inserts the `MemberProfile`, flips the invitation to `accepted`, sets `user_profile.is_active = true`, grants the `member` role, and marks any waitlist entry `joined`. Acceptance does **not** establish a session; it deletes the `access-token` cookie and redirects to a static success page. Discord is absent from the flow entirely.

The target contract (ADR 0009; ALE-156) requires stable principal and Member IDs, Phoenix-owned opaque sessions on a shared domain, the invariant that a Session implies its Member currently has club access, and DHC ownership of Members, Invitations, Roles, authorization, and Membership. This ADR fixes the integration shape under that contract.

## Decision

**The Authentication Principal is born inside acceptance.** Invitation Acceptance is the single, atomic point at which a prospective member becomes a Principal and a Member. Concretely:

- **Issue time does only one thing**: mint the invitation row — id, email, date of birth, `expires_at` (7 days), `created_by`, status `pending`. No profile, no principal, no external identity, no Stripe customer is created at issue. The `invitation.prospective_principal_id` is a fresh Phoenix UUID minted at issue; it is not a Supabase UUID and it is not resolved against any existing identity.

- **Acceptance creates the principal and the entire member-facing record set in one `Repo.transaction`:** the Principal (id = `invitation.prospective_principal_id`, authoritative email = invitation email), the `UserProfile`, the `MemberProfile` (id = `invitation.prospective_principal_id`), the `member` role, the invitation flip to `accepted`, `user_profile.is_active = true`, and the waitlist `joined` update — all commit together. The principal and the Member come into existence together; there is never a Member without a principal or a principal without a Member.

- **Acceptance does not establish a session.** It is the *registration*; it is not the login. On success the member is routed to a static success page that points to the normal sign-in path. Acceptance does not auto-send a magic link (auto-sending from a public, unauthenticated flow is a spam/abuse vector; the magic link is delivered only through the rate-limited login flow on demand).

- **The first sign-in after acceptance is a login, not a registration.** The member enters their email on the sign-in page and receives a magic link via `phx.gen.auth`'s signed-token-by-email flow. The principal email (set at acceptance from the invitation email) is the authoritative login email and the sole source of truth; `UserProfile` reaches it through its `principal_id` foreign key rather than duplicating it. There is no email-change step in acceptance; later changes follow ALE-158 (no self-service change-email; admin DB escape hatch).

- **Magic-link token exchange re-checks club access.** A valid Session implies the Member currently has club access (ALE-156). The magic-link exchange — and every login — checks `is_active` at session-creation time and refuses to mint a session for a lapsed member, surfacing a clear inactive-membership message. Magic-link delivery is not gated on Stripe state (a lapsed member can still receive the email; only the session mint is refused).

- **Discord is never part of acceptance.** Discord enters only at sign-in time, post-acceptance, via the login page — exactly as today. The first Discord sign-in reconciles against the principal that acceptance created:
  - **Email match** (Discord `email_verified: true`, accepting Discord's own verification): the Discord identity auto-links to the principal and mints a session. Frictionless.
  - **Email mismatch**: Discord alone cannot prove which principal to bind to, so the member bootstraps via a one-time magic-link login (proving control of the principal email), then links Discord from the authenticated session. ALE-158's authenticated-link path applies; `provider_subject` is the binding key and the Discord email is metadata (ALE-155).

- **Collision and replay are handled by the existing acceptance gate.** At most one pending invitation exists per email (`expire_pending_for_email` runs at issue). Acceptance locks the invitation `FOR UPDATE` and requires `status == "pending"`; a second `accept` call finds no pending invitation and rolls back. The verification token is a signed `Phoenix.Token` (15 min TTL) and is **not** single-use — its job is to prove the caller matched email+DOB at verify time; the invitation-status flip is the replay defense. An invitation whose email already maps to an existing Member is rejected by the existing `MemberProfile` existence check (rolled back as `:invalid_invitation`).

- **Pending invitations at cutover are deleted, not migrated.** Existing pending invitations are stale and will not be accepted; they are dropped at cutover. Anyone who later asks receives a fresh invitation under the new flow. The migration script (ALE-152) carries no pending-invitation state forward.

## Consequences

- The invariant "a Principal exists only for a Member" holds at all times, by construction — there is no pending-principal state to guard, no "no-session-allowed" lifecycle, and no migration question for never-accepted invitations.
- Issue time becomes trivially cheap and side-effect free (one insert); it no longer calls a Supabase admin API or creates a Stripe customer. Customer creation moves into acceptance or is driven by the Stripe webhook — to be specified by the implementation / ALE-152.
- Expired invitations leave behind only the invitation row (flipped to `expired`); no orphan `UserProfile` or principal rows accumulate, and no cleanup worker is needed.
- Re-issue is just a new invitation with a new id; acceptance builds everything fresh. No collision with stale profiles.
- The acceptance transaction shape changes: it no longer *looks up* a pre-existing `UserProfile` by `supabase_user_id`; it *creates* the principal, `UserProfile`, and `MemberProfile` together, keyed by `invitation.prospective_principal_id`. `UserProfile` loses its `supabase_user_id` lookup role; the principal's id is the join key.
- Payment idempotency within acceptance (Stripe charge surviving a late transaction rollback) is a pre-existing concern unrelated to the auth integration and is deferred to the implementation / ALE-152, not specified here.
- First-contact Discord for a mismatched-email member is a two-step dance (magic link, then link Discord from settings). This is accepted as the price of never mis-linking a Discord identity to a stranger's principal.
- ALE-152 (migration script) must preserve the Supabase UUID as the Phoenix principal/Member id for *already-accepted* members (ALE-156) and delete pending invitations at cutover rather than migrating them.

## Alternatives considered

- **Principal born at invitation issue.** Mirrors today's GoTrue shape most closely but creates a principal for a non-member, requires a "pending" principal state and careful session guards, and complicates the migration (do non-accepted invitations get principals?). Rejected: it violates the "principal only for a Member" invariant by construction.
- **Principal born lazily at first sign-in.** Maximally decouples acceptance from auth, but the first post-acceptance sign-in becomes a *registration* (new principal) rather than a *login*, and ALE-158 collision/linking policy would have to run against an email belonging to a Member with no principal — an awkward, unprecedented state. Rejected: it breaks the "no re-registration" promise and re-introduces a registration surface that acceptance was meant to replace.
- **`UserProfile` created at issue, principal at acceptance.** Keeps today's profile-at-issue shape but leaves orphan `UserProfile` rows from expired invitations and requires a cleanup worker or tolerates stale rows. Rejected: once the principal moves to acceptance, the profile has no reason to pre-exist either; symmetry dictates the whole record set is born at acceptance.
- **First-contact Discord auto-links by `provider_subject` alone on mismatch.** Rejected: `provider_subject` precedence (ALE-158) is a reconciliation rule between an identity and a *known* principal, not a discovery rule; on a first-ever Discord sign-in with a mismatched email there is no known principal to bind to, so Discord alone cannot safely establish the link.
- **Make the verification token single-use.** Rejected: it would require persisting consumed-token state for no gain, since the invitation-status flip already makes a second `accept` a no-op. The token proves verify-time credentials; the invitation is the single-use artifact.
