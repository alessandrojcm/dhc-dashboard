# ALE-155 — Discord identity portability

**Research date:** 2026-07-17  
**Question:** Can DHC import existing Supabase Discord identities into Phoenix-owned authentication so the next Discord sign-in reaches the same Member without relinking or replaying Onboarding?

## Conclusion

Yes. Import each validated Supabase Discord identity as an External Identity keyed by `(provider = "discord", provider_subject = auth.identities.provider_id)` and linked to the Phoenix Authentication Principal that preserves the source `auth.users.id`. On a later Discord callback, Assent normalizes Discord's current user `id` into `sub`; an exact `(discord, sub)` lookup therefore reaches the already-linked principal and Member.

This preserves the identity link, not the Supabase session or OAuth tokens. The accepted cutover permits a one-time sign-out, so the member must complete a normal Discord OAuth sign-in after cutover but does not have to reconnect the identity from an authenticated account, re-register, or replay Onboarding.

No executable import prototype is required to establish portability. The source-to-target key equivalence is explicit in first-party documentation and source, and the production-shaped rehearsal has already demonstrated the expected row shape. Production preflight checks and migration reconciliation remain mandatory; they provide evidence about DHC's real data that a throwaway OAuth prototype would not.

## Documented key equivalence

Supabase documents `auth.identities.provider_id` as the identifier returned by the provider and, for OAuth, as the user's account identifier at that provider. Supabase Auth constructs an identity by assigning normalized provider claim `sub` to `ProviderID`, persists it as `provider_id`, and looks identities up by `provider_id` plus `provider`.

Discord documents the OAuth `identify` scope as allowing `/users/@me`, whose User object contains the account's `id` as a snowflake. The optional `email` scope adds `email` and `verified`; username is explicitly non-unique. Discord does not state a separate formal immutability warranty for User IDs, so the precise contract is that `id` is Discord's user identifier, not that every conceivable account lifecycle preserves it.

Assent's Discord strategy requests `identify email`, fetches `/users/@me`, and normalizes the returned fields as follows:

```elixir
%{
  "sub" => user["id"],
  "preferred_username" => user["username"],
  "email" => user["email"],
  "email_verified" => user["verified"],
  "picture" => ...
}
```

The portable chain is therefore:

```text
Discord /users/@me id
  → Supabase normalized sub
  → auth.identities.provider_id
  → Phoenix External Identity provider_subject
  ← Assent normalized sub
  ← Discord /users/@me id
```

The production-shaped migration rehearsal found one Discord identity whose `provider_id`, payload `sub`, and payload `provider_id` agree and whose owner is a coherent active Member. That proves the direct transformation against the representative schema, but not the state of production.

## Migration contract

For every principal selected by the production migration:

1. Select Discord identities by `auth.identities.provider = 'discord'`.
2. Require non-empty `provider_id` and exact agreement with `identity_data->>'sub'`; if the payload also contains `provider_id`, require it to agree too.
3. Insert an External Identity with provider `discord`, provider subject copied exactly as a string from `auth.identities.provider_id`, and principal ID copied from `auth.identities.user_id`.
4. Require that the principal preserves that source `auth.users.id` and resolves to exactly one eligible Member.
5. Enforce uniqueness on `(provider, provider_subject)` and `(principal_id, provider)` before enabling login.
6. On callback, locate the External Identity only by `(discord, Assent user["sub"])`; never infer or change a link from email, username, display name, or avatar.
7. Treat Discord email and `email_verified` as refreshable metadata only. The invitation-authoritative principal email remains the sole magic-link target.

Store Discord snowflakes as strings (or a lossless database integer), never as JavaScript numbers, because their values can exceed JavaScript's safe-integer range. No Supabase access token, refresh token, provider token, or Supabase session needs to be imported for this login contract.

## Hard gates and unsupported paths

Abort migration or exclude a row only through the separately approved anomaly process when any of these occur:

- a Discord identity lacks a provider subject or its persisted subject fields disagree;
- the same `(discord, provider_subject)` belongs to multiple source users;
- one principal has repeated Discord identities;
- the identity owner is absent from the selected principal set or does not resolve to the expected Member;
- insertion violates either target uniqueness constraint;
- source and inserted Discord identity counts do not reconcile.

The migration cannot preserve Discord login for an account that has no persisted Discord identity, cannot prove control of a deleted or inaccessible Discord account, and must not repair ambiguous ownership by matching email. Such a member retains magic-link access and may explicitly link Discord later under the collision and recovery policy.

A changed Discord email, username, or avatar does not change the link because none is an identity key. An OAuth failure, revoked authorization, or a new consent prompt can prevent or interrupt a particular sign-in, but does not require DHC to recreate the imported database association when Discord returns the same User ID on a successful flow.

## Prototype decision

Do not add a throwaway executable prototype to this map.

- **Already proven from source:** Supabase persists normalized `sub` as `provider_id`; Assent normalizes Discord `id` back to `sub`.
- **Already rehearsed locally:** the production-shaped row uses matching subject fields and resolves to a Member.
- **Still required before cutover:** run aggregate production preflight gates, dry-run the specified migration transformation, and reconcile source/target counts.
- **Belongs to implementation verification:** an integration test should later seed an imported External Identity, simulate an Assent callback with the same `sub`, and assert that Phoenix creates a session for the existing principal and Member. That is implementation work beyond this planning map, not a discovery prototype.

## Primary sources

- [Supabase Auth: Identities](https://supabase.com/docs/guides/auth/identities) — `provider_id`, `user_id`, identity metadata, and provider semantics.
- [Supabase Auth `Identity` model](https://github.com/supabase/auth/blob/master/internal/models/identity.go) — `sub` assignment to `ProviderID` and provider-plus-ID lookup.
- [Discord User resource](https://docs.discord.com/developers/resources/user) — User `id`, username uniqueness, email fields, scopes, and `/users/@me` behavior.
- [Discord OAuth2](https://docs.discord.com/developers/topics/oauth2) — `identify` and `email` scope semantics and OAuth state requirements.
- [Assent Discord strategy](https://github.com/pow-auth/assent/blob/main/lib/assent/strategies/discord.ex) — endpoints, default scopes, and normalized claims.
- [Authentication population migration rehearsal](./ale-149-auth-population-migration-rehearsal.md) — DHC's production-shaped identity observations and mandatory production gates.
