# CONTEXT: DHC Dashboard

**Last updated:** 2026-07-17
**Status:** Active migration from SvelteKit + Supabase + Deno edge functions to Phoenix + Ecto + Oban

## Domain Language

| Term | Definition |
|------|-----------|
| **Member** | A person with a club membership. Owns club profile facts such as identity, contact data, and preferred weapon. Its `user_profiles.principal_id` links to the DHC-owned Phoenix Authentication Principal. |
| **Authentication Principal** | The DHC-owned login identity for exactly one Member. It owns the authoritative login email and may have login methods such as magic link or linked External Identities. A principal may establish a Session only while its Member has club access; pending Invitations do not yet have principals. A Principal links to exactly one UserProfile via `user_profiles.principal_id` (unique), and exactly one MemberProfile via `member_profiles.id` (which equals the Principal ID); database constraints enforce that both links refer to the same Principal, preventing linkage drift. |
| **External Identity** | An account at an external identity provider that is explicitly linked to one Authentication Principal. Its immutable provider subject, not its reported email or username, establishes the link. A principal has at most one identity per provider, and an external account cannot belong to multiple principals. |
| **Session** | A revocable, per-device authenticated relationship between a browser and an Authentication Principal. A valid Session implies that the associated Member currently has club access; identity proof without club access is not an authenticated dashboard Session. |
| **Membership** | A recurring subscription/access relationship managed via Stripe. Owns subscription and access state such as `active`, `inactive`, or `paused`, pause-until dates, and Stripe customer/subscription linkage. An inactive Membership means the member has no active subscription. |
| **isActive** | A projection of Membership subscription state onto `user_profiles.is_active`, written by the Stripe webhook — a member is active iff they have club access, including a paused Membership. It is NOT independently admin-settable; there is no API endpoint that writes it. Stripe is the source of truth; a missed webhook leaves the projection stale (drift risk). A Member must be active to establish or continue an authenticated dashboard Session. Distinct from `membershipStatus`, which also encodes `paused`. |
| **Paused** | A Membership status where `subscription_paused_until` is in the future. The Member retains access (`isActive = true`) but is not charged. |
| **Workshop** | A scheduled club activity with date, capacity, pricing, and registration. Use Workshop in domain/API language; `club_activity_*` is persistence vocabulary. |
| **Registration** | A member's sign-up for a workshop. Has statuses (confirmed, cancelled, waitlisted) and links to payment. A cancelled or refunded Registration is a closed chapter — it stays as historical record but no longer blocks a fresh Registration for the same member and workshop. Uniqueness is enforced only among active registrations (pending or confirmed); multiple historical rows per member per workshop are permitted. Payment identity is split: member Registrations carry a `stripe_payment_intent_id`, external Registrations carry a `stripe_checkout_session_id`; a CHECK constraint enforces exactly one is set per row. |
| **Refund** | A cancellation-triggered repayment. Tracked in `club_activity_refunds`. |
| **Retention Policy** | Financial and audit records (Registrations, Refunds, inventory history) are retained permanently — `ON DELETE RESTRICT` prevents destroying them when a parent is removed. Workshops with Registrations and Members are soft-deleted (archived), never hard-deleted; a Member may be anonymized or detached from personal data without destroying transactional records. Workshops with zero Registrations, empty containers, unused equipment categories, inventory items, orphaned notifications, expired/revoked Invitations, and external users with zero Registrations may be hard-deleted. Registrations carry an attendee snapshot (display name, email) captured at transaction time so profile anonymization does not corrupt event and payment history. The inventory-history retention clause (`ON DELETE SET NULL` so items can be hard-deleted while history survives) is target-state, not yet enforced — deferred until the equipment domain goes production-ready. |
| **Inventory** | Club equipment (swords, masks, etc.) tracked in containers/categories with movement history. |
| **Invitation** | A pending or processed invite for a prospective member. Can be sent with or without a Stripe subscription. At most one pending Invitation exists per canonical email at any time; expired, accepted, or revoked Invitations accumulate as history and do not block reissue. Each pending Invitation carries a pre-allocated Principal UUID (its `prospective_principal_id`) used at acceptance; a fresh UUID per issue avoids conflict. |
| **Invitation Acceptance** | The atomic Onboarding conversion event where a prospective member accepts an invitation and becomes a Principal and a Member in one database transaction. Issue time records only the invitation (id, email, DOB, expiry); acceptance creates the Principal, `UserProfile`, `MemberProfile`, and `member` role together, keyed by `invitation.user_id`. When the invitee has an existing waitlist UserProfile, acceptance claims and activates that profile (setting `principal_id`, `is_active`) rather than creating a duplicate — guardian linkage and intake-captured fields (gender, pronouns, medical conditions) carry over. For direct invitations without a waitlist entry, a new profile is created. Acceptance is the registration; it does not establish a session. Discord enters only at sign-in time, post-acceptance, via the login page — never inside acceptance. |
| **Onboarding** | The end-to-end journey from prospective member intake through invitation acceptance and member record creation. Waitlist is the intake side of Onboarding; Invitations are the conversion side. |
| **Notification** | A per-user in-app message generated by the system. Ordered by creation time and unread until `readAt` is set; users only see their own notifications. |
| **Waitlist** | Prospective members awaiting invitation. A distinct domain area within Onboarding, not merely part of Member management. |
| **Waitlist Status** | The stage of a prospective member on the waitlist: waiting, invited, paid, deferred, cancelled, completed, no_reply, or joined. |
| **Settings** | Cross-domain or system-wide configuration that is managed as configuration rather than as part of a specific domain workflow. A value stored in the settings table is not automatically a Settings capability concern; domain-owned values such as Waitlist availability should be exposed through their owning domain language. |
| **Role** | An authorization level assigned to a user. Drawn from `role_type` enum (admin, president, member, committee roles). |

## Active ADRs

| # | Title | Status |
|---|-------|--------|
| 0001 | Phoenix Takes Over Database Ownership | Accepted |
| 0002 | RLS Removal Strategy | Accepted |
| 0003 | API-First Design with OpenAPI Spec | Accepted |
| 0004 | Migrate Deno Edge Functions to Oban | Accepted |
| 0005 | Migrate PostgREST Reads to Domain Phoenix APIs | Accepted |
| 0006 | Testcontainers-Driven Phoenix Test Harness | Accepted |
| 0007 | Members and Membership share storage but expose separate API boundaries | Accepted |
| 0008 | Stripe owns Membership state; DHC owns Member profile facts | Accepted |
| 0009 | Phoenix owns authentication | Accepted |
| 0010 | Authentication within Invitation Acceptance | Accepted |

## Architecture (Target State)

```
SvelteKit (Cloudflare Pages)
    │
    │ HTTP (JSON, typed via generated OpenAPI client)
    ▼
Phoenix (Fly.io)
    │
    ├── Ecto → Postgres (Supabase-hosted)
    ├── Oban → Postgres (same instance, separate tables)
    ├── Phoenix Auth (`phx.gen.auth`) → magic links, principals, and sessions
    ├── Assent → Discord OAuth
    └── Stripe API (outbound webhook calls, inbound webhook handling)
```

## Test Harness Language

| Term | Definition |
|------|-----------|
| **Test Harness** | The automated execution environment for a given suite. Distinct from the data it runs against. Two harnesses exist: the Phoenix (Elixir) harness and the Playwright (E2E) harness. |
| **Characterization Test** | A test that pins the *current* behavior of an affected code path before a migration changes it — even if that behavior is defective. Written first, it goes red when the fix lands (confirming the behavior changed); a companion test asserting the *desired* behavior then goes green. Required before any schema-migration ticket that touches an untested path, per the audit finding that moduledoc-claimed behavior is often not asserted by any test. |
| **Test Fixture** | The per-test setup data. Inserted and torn down by the test itself, not the harness. |
| **Postgres Surface** | The minimal dependency for the Phoenix harness: a Postgres container plus a seeded `auth` schema (GoTrue-owned tables such as `auth.users`). No HTTP services. |
| **Supabase Surface** | The full dependency for the E2E harness: Kong + GoTrue + PostgREST + Postgres. Required because E2E seeds/teardowns via the Supabase HTTP API and derives the auth cookie name from the project ref host. |
| **Auth Schema Bootstrap** | The `auth` schema DDL the Phoenix harness relies on. The `supabase/postgres:17.6.1.136` image already ships `00000000000001-auth-schema.sql` at container init, creating the full `auth.users` table, `auth.schema_migrations`, and the `supabase_auth_admin` role. No bespoke bootstrap file is needed; the image is the bootstrap. GoTrue's own migrations run `CREATE TABLE IF NOT EXISTS`, so in the `supabase` profile GoTrue boots cleanly against the image-seeded table. |
| **Shared Container** | A single testcontainer started once per `mix test` run (in `test_helper.exs`) and shared across all test cases via the Ecto SQL Sandbox. Distinct from per-test isolation (which the sandbox provides) and from per-test-case containers (rejected as too slow). |
| **Compose-Driven Harness** | Both test harnesses drive the same stripped Supabase `docker-compose.yml` via `Testcontainers.DockerCompose` (Phoenix) and `docker compose` CLI (E2E). The compose file is the single source of truth for the stack shape; profiles gate which services each harness starts. |
| **Per-Run Lifecycle** | The Phoenix harness does a full compose `up` at `mix test` start and `down -v` on `System.at_exit`. No cross-run reuse — every run starts from a freshly migrated DB with the Auth Schema Bootstrap applied. Deterministic at the cost of ~2-4s cold start; reuse is a deferred optimization. |
| **Migration Deploy Shape** | Schema migrations run at deploy time via the Fly release command. Additive migrations (new indexes, nullable columns, non-conflicting CHECK constraints) deploy routinely. Destructive or non-splittable changes (column type changes, citext casts, index drops that change uniqueness semantics) use expand-contract where possible (expand → backfill → contract) and a maintenance window with write freeze for the contract step or for changes that cannot be split. Each migration ticket declares its deploy shape so the operator knows which require coordination. |
| **E2E Deferral** | The Playwright harness E2E migration is out of scope for the current work. Only Phoenix is being reworked now. The compose file shape must support E2E later (profiles, Kong/GoTrue/PostgREST), but E2E's fixed-port and cookie-derivation concerns are deferred. |
| **Uniform Profiles** | Every service in the stripped compose file carries a `profiles:` entry — `db` for Postgres (+ Auth Schema Bootstrap), `supabase` for GoTrue/Kong/PostgREST. No default-always services. Phoenix starts with `with_profile("db")`; E2E will later start with `with_profile("supabase")` (and `with_profile("db")` if it needs the DB too).
| **Ephemeral DB Volume** | The Phoenix harness runs the `db` service with no persistent `PGDATA` volume — `down -v` on `System.at_exit` destroys all data. Fresh container, fresh migration, fresh `auth` schema per `mix test` run. No upstream Supabase init-SQL mounts are needed; the `supabase/postgres` image already ships `auth.users` and `pg_jsonschema`. |
| **Root Compose File** | The stripped Supabase `docker-compose.yml` lives at the repo root next to the existing root `.env`. This lets Compose's built-in `.env` resolution interpolate `${POSTGRES_PASSWORD}` etc. without plumbing env vars through `DockerCompose.with_env/3` or duplicating the env file. testcontainers-elixir's `DockerCompose.new/1` sets `cd` to the compose file's directory, so a root-level file means `cd: repo_root` where `.env` already sits. | |

## Migration State

- **Phase 1a**: Edge functions → Oban (in progress)
- **Phase 1b**: Service layer → Phoenix API (next)
- **Phase 2**: LiveView migration (future evaluation)

Supabase-hosted Postgres and Storage remain in place throughout Phase 1. Phoenix owns authentication through generated Principals, magic links, opaque database-backed Sessions, and Assent Discord OAuth. M2 repointed application ownership and foreign keys to `principals.id`; Supabase `auth.*` remains only as rollback dead weight during observation and until the separate Postgres-hosting migration. PostgREST and RLS policies are removed when all data access is proxied through Phoenix.
