# ALE-149 — Authentication population migration rehearsal

**Rehearsal date:** 2026-07-17  
**Question:** Which sanitized aggregate checks and migration gates does the production-like Supabase Auth mock dataset establish for the Phoenix-auth migration?

## Safety and method

The configured Supabase mock dataset was queried read-only. This dataset mimics the production data shape and is useful for designing and rehearsing the migration, but its counts are not measurements of the live production population. The queries returned only counts, provider names, JSON key names, and consistency predicates. They did not select UUIDs, email addresses, credentials, provider subjects, names, or identity payload values.

The migration script and cutover runbook must run these same checks against production immediately before migration. Production results, not the rehearsal counts below, determine the final row set and whether cutover may proceed.

## Mock population summary

| Population | Count |
|---|---:|
| Non-deleted `auth.users` | 314 |
| Active `user_profiles` linked to those users | 314 |
| Coherent active Members: auth user + active user profile + `member_profiles` row | 312 |
| Active linked profiles without a `member_profiles` row | 2 |
| Historical inactive `user_profiles` without an auth user or Member row | 508 |
| Deleted, anonymous, currently banned, unconfirmed, or email-less auth users | 0 |

In the representative dataset, the migratable happy path is 312 coherent Members. Two mock auth principals exercise a violation of the target one-principal/one-Member invariant: each has an active `user_profiles` row but no `member_profiles` row and no role. The migration specification needs an explicit repair, exclusion, or abort policy for this scenario whether or not production currently contains it. The 508 mock inactive historical profiles exercise the rule that profiles without current auth users must not be turned into Phoenix authentication principals.

All 312 mock `member_profiles.id` values match an existing auth user and match the linked `user_profiles.supabase_user_id`, demonstrating the direct UUID-preservation path. No mock `user_roles` row points at a missing auth user. Both mock Invitation records point at valid auth users and linked profiles, and there are no pending Invitations in this rehearsal dataset.

## Login-method and identity shape

| Identity shape | Users |
|---|---:|
| Email identity only | 313 |
| Email plus Discord identities | 1 |
| Discord identity only | 0 |
| No identity | 0 |
| More than one identity | 1 |

The mock dataset has 314 email identities and one Discord identity. “Magic-link-only” here means that the current application exposes only email magic-link login for the 313 mock users without Discord; it does **not** mean their Supabase password hash is empty. Every mock auth row has a non-empty encrypted-password field, but password login is not part of the application contract and those hashes need not be imported into the Phoenix magic-link target.

The mock Discord identity demonstrates the direct portability path:

- its `provider_id`, payload `sub`, and payload `provider_id` are present and equal;
- its identity email and payload email equal the auth user’s normalized login email;
- it belongs to an active linked Member;
- no provider subject is shared across users and no user has repeated identities for one provider;
- observed payload keys are `avatar_url`, `custom_claims`, `email`, `email_verified`, `full_name`, `iss`, `name`, `phone_verified`, `picture`, `provider_id`, and `sub`.

Only the immutable Discord provider subject is migration-critical. Email, names, and avatar fields remain metadata and must not be used to infer or relink identity.

## Email and activity checks

Across non-deleted mock auth users:

- no email is missing;
- no normalized email is duplicated;
- no email changes under lowercase-and-trim normalization;
- every email identity’s email matches its auth user’s normalized email;
- every email identity subject matches its auth user UUID;
- `raw_app_meta_data.providers` agrees with the persisted identity set for every user.

The mock dataset contains no email collision. The migration must enforce globally unique normalized principal emails and abort on any collision found in the production pre-cutover run.

The mock sign-in history is deliberately sparse: 313 users have no `last_sign_in_at`, while one signed in within the last 30 days. This exercises the rule that migration eligibility is based on the Member/access relationship, not sign-in recency.

## Required migration gates

The production migration specification should turn the rehearsed aggregates into hard gates:

1. Select principals from non-deleted auth users joined to active user profiles and valid Members; never reconstruct principals from historical profiles that lack auth users.
2. Preserve each selected Supabase UUID as the Phoenix principal ID and validate `member_profiles.id = user_profiles.supabase_user_id = auth.users.id`.
3. If production contains active profiles without Members, resolve or explicitly exclude them before migration; Phoenix must not issue sessions for them.
4. Import one normalized login email per selected principal and abort on missing or duplicate normalized emails.
5. Import email identities only as evidence of the existing login method; do not copy encrypted password hashes into the magic-link-only target.
6. Import Discord identities by `(provider = 'discord', provider_id)` and validate that `provider_id`, payload `sub`, and payload `provider_id` agree. Never link by Discord-reported email.
7. Abort on repeated provider identities per principal, provider subjects shared across principals, missing identity owners, or Member-link mismatches.
8. Run every aggregate against production immediately before cutover and reconcile the production counts against inserted principals and external identities. Mock counts must never be used as expected production totals.

## Read-only query set

The profiling used these query families:

- **Principal population:** aggregate `auth.users` by deletion, confirmation, anonymous, ban, email presence, and sign-in recency.
- **Provider rollup:** group `auth.identities` by `provider` and by `user_id`; detect missing identities, multiple identities, repeated providers per user, and provider subjects shared across users.
- **Email quality:** group `lower(btrim(email))` to detect collisions; compare auth-user, identity, and Discord-payload emails only through aggregate equality predicates.
- **Discord portability:** count missing or unequal `provider_id`, `identity_data->>'sub'`, and `identity_data->>'provider_id'`; enumerate payload key names without selecting values.
- **Member integrity:** join `auth.users.id`, `user_profiles.supabase_user_id`, `member_profiles.id`, and `member_profiles.user_profile_id`; group only by active/link-presence booleans.
- **Dependent references:** count orphaned `user_roles.user_id` and `invitations.user_id` references.

Each query must remain aggregate-only when run against production. Investigating any production anomaly should happen separately under controlled operational access; no personal identifiers belong in this artifact or its tracker comments.
