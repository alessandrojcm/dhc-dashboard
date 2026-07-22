# Supabase Auth replacement comparison

**Research date:** 2026-07-17

> **Subsequent decision:** DHC requires the authentication user directory to remain in its own Postgres database. Hosted directories were therefore eliminated, and [ADR 0009](adr/0009-phoenix-owns-authentication.md) selects Phoenix 1.8 generated authentication plus Assent. Discord/email mismatch is not a migration blocker: the invitation email remains authoritative and magic-link login remains available when Discord is not linked.

## Scope and interpretation

DHC needs Discord OAuth and email magic-link sign-in, with current Members and their Supabase-auth associations surviving without re-registration. Phoenix remains the authority for Members, Invitations, Roles, authorization, and Membership; an auth provider owns login methods, external identities, and sessions.

“Preserve identity” therefore has two layers:

1. DHC keeps an immutable mapping from the current `auth.users.id` to its new principal, so existing Member foreign keys are never inferred from email.
2. The replacement must recognize the same Discord account and email owner. A provider does **not** need to adopt the Supabase UUID as its native ID if DHC retains that mapping.

No reviewed managed provider documents a lossless import of an already-linked Supabase Discord identity as its own native social identity. Managed candidates therefore need a small import/linking proof before selection.

## Comparison

| Option | Mandatory sign-in methods | Migration and linking | Integration / ownership | Cost and lock-in | Verdict |
|---|---|---|---|---|---|
| Phoenix 1.8 `phx.gen.auth` + Assent | Phoenix generates email authentication and magic links; Assent includes a maintained `Assent.Strategy.Discord`. | DHC owns principal and identity tables, so it can import Supabase UUIDs and Discord provider IDs exactly and define collision policy explicitly. This is application work, not a generator feature. | Native Phoenix/Ecto. Phoenix owns an opaque browser session or bearer token; SvelteKit remains a client. Highest security and operational responsibility, lowest external lock-in. | OSS/infrastructure cost only; all schema and identity data are directly exportable. | **Shortlist. Best control and migration fidelity.** |
| Pow + PowAssent | PowAssent documents Discord and multiple linked providers; Pow provides registration, sessions, confirmation, and invitations. Neither reviewed guide documents magic-link login as a first-class flow. | Own Ecto tables make exact import possible; PowAssent supplies a user-identity table and linking flows. Magic-link login and DHC-specific collision rules remain custom. | Phoenix-native, but introduces a framework over code DHC would otherwise own. Latest visible releases are Pow 1.0.39 (2025-01) and PowAssent 0.4.18 (2024-02). | OSS and exportable, with maintenance dependency on two libraries. | Viable but dominated by the official generator plus a smaller OAuth library. |
| AshAuthentication | Documents magic links, OAuth2, multiple `UserIdentity` records, bearer/session loading, and Phoenix integration. | Self-owned storage permits exact import, but DHC would first adopt Ash resources, AshPostgres, policies, token resources, and its supervisor. | Strong if the application already uses Ash; DHC uses Ecto directly, so this changes the application framework to solve authentication. | OSS and exportable, but high framework lock-in and adoption cost. | Reject for this migration unless Ash is independently chosen for the backend. |
| Auth0 | Custom Social Connections can connect any OAuth2 provider, so Discord is feasible. Email magic links exist, but only in Classic Login and must complete in the same browser. | Bulk import is for database connections. Account linking is explicit, requires both identities to authenticate, does not merge metadata, and is plan-dependent. Keep the Supabase UUID in DHC; prove pre-created email user + returning Discord identity linking. | OIDC/JWT boundary is suitable for Phoenix and SvelteKit; Auth0 operates credentials, sessions, attack protection, and email flow. | Free up to 25k MAU; account linking is absent from Free and included from Essentials. Exports exist, but provider IDs, sessions, and flow configuration create vendor lock-in. | **Conditional shortlist. Mature, but the magic-link UX and linking plan are material drawbacks.** |
| Clerk | Native Discord connection and email verification links. | Migration docs explicitly recommend storing the old ID as `external_id`, exposing it in session claims, and allow full user/password-hash export. Clerk automatically links an OAuth identity when its verified email matches an existing verified account; different-email linking requires the user to add that email. Prove the exact Supabase Discord/email cases before selection. | Browser/session product with custom JWTs and backend APIs; Phoenix can validate the session JWT and use the legacy ID claim. No Elixir-specific SDK is required for that boundary, but SvelteKit becomes Clerk-aware. | Hobby includes 50k retained users, full exports, three social connections, and five impersonations; Pro starts at $25/month. Strongest frontend and session coupling of the shortlist. | **Shortlist. Best managed fit if automatic email linking matches production identities.** |
| Stytch | Stytch markets OAuth, magic links, and sessions and includes 10k MAU on its published pricing. | The reviewed first-party material did not establish import of existing Discord identities, deterministic collision/linking behavior, or a complete user export contract. | Managed API/session model should be technically callable from both runtimes, but migration guarantees are insufficiently documented for DHC's hard requirement. | Usage pricing; custom branding is $99/month. Exit guarantees remain unclear from the reviewed sources. | Do not shortlist without written vendor answers or a targeted prototype. |
| WorkOS AuthKit | Its current Social Login page lists Google, Microsoft, GitHub, Apple, GitLab, LinkedIn, and Slack—not Discord. “Magic Auth” is a six-digit emailed code, not a link. | Migration details cannot compensate for two mandatory sign-in gaps. | Standards-based managed integration and attractive operational model. | First 1m MAU free; custom domain $99/month. | Reject: current first-party docs do not offer Discord or email magic links. |
| ZITADEL Cloud | Supports configurable identity providers and passwordless mechanisms broadly, but the reviewed current docs did not establish a Discord flow plus email magic-link login as a supported combination. | Open-source/self-host option reduces exit risk, but migration/linking semantics still require custom work and proof. | OIDC is a clean Phoenix/SvelteKit boundary. | Cloud Free has 100 daily active users; Pro starts at $100/month. Self-hosting adds operations. | Do not shortlist until both mandatory methods are demonstrated from current docs. |

## Shortlist

### 1. Phoenix-owned auth: `phx.gen.auth` + Assent Discord

This is the control candidate. Phoenix 1.8's generator produces editable email-authentication code and documents the security rules around magic-link confirmation. [Assent](https://github.com/pow-auth/assent) provides the Discord OAuth protocol step, while DHC owns the principal, external-identity, session, recovery, and audit model. OAuth challenge and callback handling stay behind a small library seam; DHC creates and links users and authenticates subsequent requests.

This option best guarantees preservation because migration inserts DHC-owned rows rather than asking a vendor to recreate Supabase's identity graph. Its cost is engineering and ongoing security ownership.

### 2. Clerk

Clerk is the strongest managed candidate. It documents [Discord sign-in](https://clerk.com/docs/guides/configure/auth-strategies/social-connections/discord), [email verification links](https://clerk.com/docs/guides/configure/auth-strategies/sign-up-sign-in-options), [legacy IDs through `external_id`](https://clerk.com/docs/guides/development/migrating/overview), [full exports](https://clerk.com/docs/guides/development/migrating/overview#migrating-from-clerk), and [automatic verified-email account linking](https://clerk.com/docs/guides/configure/auth-strategies/social-connections/account-linking). Its automatic linking policy is convenient but must match DHC's production collision policy; email equality alone must not silently rebind a Member in an unsafe case.

### 3. Auth0, conditional

Auth0 has the broadest identity-management surface: [generic OAuth2 social connections](https://auth0.com/docs/authenticate/identity-providers/social-identity-providers/oauth2), [bulk database-user imports](https://auth0.com/docs/manage-users/user-migration/bulk-user-imports), and explicit [account linking](https://auth0.com/docs/manage-users/user-accounts/user-account-linking). It remains conditional because [magic links require Classic Login and the same browser](https://auth0.com/docs/authenticate/passwordless/authentication-methods/email-magic-link), and account linking is gated by plan. Those constraints may make it worse than Clerk for DHC despite greater configurability.

## Superseded managed-provider proof plan

This proof is no longer required because hosted user directories do not satisfy DHC's ownership requirement. Before that criterion was established, the proposed next step was to run one throwaway Clerk tenant and repeat it for Auth0 only if its Classic Login limitation was acceptable.

1. Pre-create a user carrying a known Supabase UUID as legacy metadata/external ID.
2. Sign in using the same Discord application and Discord user ID currently stored by Supabase.
3. Verify whether the provider links to the pre-created principal, creates a duplicate, or requires explicit reauthentication.
4. Repeat with matching and non-matching Discord/email addresses and with unverified/missing email.
5. Confirm Phoenix receives a stable signed subject plus DHC legacy ID, and that SvelteKit can refresh/revoke the session without holding a provider secret.
6. Export the resulting user and verify that DHC can recover the provider subject, legacy UUID, email identity, and Discord identity needed for a future exit.

This proof establishes provider behavior only. The production population profile and DHC collision/recovery policy belong to their own wayfinding tickets.

## Primary sources

- Phoenix [`mix phx.gen.auth`](https://hexdocs.pm/phoenix/Mix.Tasks.Phx.Gen.Auth.html)
- [Assent](https://github.com/pow-auth/assent)
- [Pow](https://github.com/pow-auth/pow) and [PowAssent](https://github.com/pow-auth/pow_assent)
- [AshAuthentication getting started](https://hexdocs.pm/ash_authentication/get-started.html)
- Auth0 [custom OAuth2 connections](https://auth0.com/docs/authenticate/identity-providers/social-identity-providers/oauth2), [magic links](https://auth0.com/docs/authenticate/passwordless/authentication-methods/email-magic-link), [account linking](https://auth0.com/docs/manage-users/user-accounts/user-account-linking), [bulk import](https://auth0.com/docs/manage-users/user-migration/bulk-user-imports), and [pricing](https://auth0.com/pricing)
- Clerk [Discord](https://clerk.com/docs/guides/configure/auth-strategies/social-connections/discord), [sign-in methods](https://clerk.com/docs/guides/configure/auth-strategies/sign-up-sign-in-options), [migration/export](https://clerk.com/docs/guides/development/migrating/overview), [account linking](https://clerk.com/docs/guides/configure/auth-strategies/social-connections/account-linking), and [pricing](https://clerk.com/pricing)
- Stytch [documentation](https://stytch.com/docs) and [pricing](https://stytch.com/pricing)
- WorkOS [Social Login](https://workos.com/docs/authkit/social-login), [Magic Auth](https://workos.com/docs/user-management/magic-auth), and [pricing](https://workos.com/pricing)
- ZITADEL [documentation](https://zitadel.com/docs) and [pricing](https://zitadel.com/pricing)
