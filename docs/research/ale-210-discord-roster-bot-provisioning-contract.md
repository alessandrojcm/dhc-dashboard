# ALE-210 — Discord roster bot provisioning contract

**Decision date:** 2026-08-13  
**Status:** Accepted operational contract for ALE-205  
**Scope:** Provision and prove the minimum Discord capability required to read
the DHC guild roster for the one-off existing-Member prefill. This document
does not implement a bot, a roster client, persistence, or the prefill.

## Decision summary

Provision a new, DHC-owned Discord Developer Portal application solely for the
roster prefill. Create its bot user, install it only in the DHC guild, and give
it zero guild permissions. Do **not** extend the existing interactive Discord
OAuth application and do not reuse its client secret, callback, or token.

The bot's only permitted operation is `GET /guilds/{guild.id}/members` during
the controlled prefill. It is a roster-reading integration, not a Member
identity, a dashboard authentication mechanism, or a permanent guild service.

## Operational contract

### Ownership and credentials

| Item | Contract |
| --- | --- |
| Discord ownership | Create the application under a DHC-controlled Discord Developer Team, not an individual's personal application. At least two current DHC administrators must retain Developer Team access; designate and document the Team owner and a recovery contact. |
| Existing OAuth client | `DISCORD_CLIENT_ID` and `DISCORD_CLIENT_SECRET` remain credentials for the Member-facing OAuth application only. They must not be copied to or used by the roster task. |
| Bot token | Store the new bot token only as `DISCORD_ROSTER_BOT_TOKEN` in the production secret store. The value is a bearer credential; never commit it, include it in a fixture, log it, or expose it to browser code. Rotate it if it is displayed, exported, or suspected exposed. |
| Guild configuration | Store the target guild snowflake as `DISCORD_ROSTER_GUILD_ID`. It is configuration, not a secret, but is supplied only to the roster task; treat it as an opaque string, not a number. Store the expected bot application ID as `DISCORD_ROSTER_BOT_APPLICATION_ID`; it is required for the provisioning preflight identity check, though not for roster pagination. |
| Access ownership | The DHC operations owner controls the Developer Team and vault entries. The ALE-205 executor receives temporary, audited access only to the roster task's required values. The dashboard runtime, browser, CI, and normal developers do not receive the bot token. |

The named values are the contract for the later task; adding them to Phoenix
runtime configuration is deliberately deferred until roster tooling exists.

### Application and guild installation

1. Create the separate application and bot user in the DHC-controlled Developer
   Team. Record the application ID in the execution record.
2. On the application's **Bot** settings page, enable only the
   `GUILD_MEMBERS` privileged intent. Do not enable `GUILD_PRESENCES` or
   `MESSAGE_CONTENT`.
3. Keep **Public Bot** disabled if the Developer Portal permits it for this
   DHC-only use. This prevents an arbitrary guild administrator from installing
   the bot elsewhere.
4. Install the bot once, to `DISCORD_ROSTER_GUILD_ID`, via Discord's bot
   authorization flow with `scope=bot`, `permissions=0`, the configured
   `guild_id`, and `disable_guild_select=true`. The installing operator must
   confirm Discord's dialog names the DHC guild and the separate application.
5. Verify from the DHC guild's integrations/member administration surface that
   the installed bot has the recorded application ID and no role or granted
   permissions beyond Discord's unavoidable baseline membership.

`permissions=0` deliberately requests no channel, message, moderation,
management, or invitation capability. The guild-member list endpoint's
privileged-intent requirement is not a reason to grant those permissions.

### Privileged-intent approval preflight

Before installation, the DHC operations owner must open the separate
application's Bot settings and record one of these outcomes:

- `GUILD_MEMBERS` can be enabled for the application; or
- Discord requires privileged-intent access review, the review is approved, and
  the intent is then enabled.

The current Discord documentation says applications with fewer than 10,000
unique users across the servers where the app is visible can enable privileged
intents in the Developer Portal; apps at or above that threshold require
continued access review. This threshold is a Discord policy fact, not an
assumption about DHC's guild size. Discord's portal state is the authoritative
preflight result for the actual application. Do not begin a backfill based only
on the expectation that the DHC guild is small.

### Execution environment

Roster access runs only as a one-shot, operator-invoked administrative task in
an approved production-capable environment (a controlled administrator
workstation or ephemeral one-off runner). It must not run in a Phoenix web
request, Oban worker, Fly Machine, browser, CI job, cron, or a developer's
ordinary local environment.

The task runner has a dedicated, audited secret-store access path limited to
the bot token and guild configuration plus the minimum DHC access that ALE-205
later specifies for staged assignments. It must not inherit the general
production secret bundle merely for convenience. Its execution record contains
the operator, timestamp, application ID, configured guild ID, tool revision,
and preflight result, but never the bot token or complete roster data.

### Required roster-access proof

Provisioning is incomplete until a credentialed preflight succeeds from the
same task environment intended for the prefill. The preflight must:

1. Load `DISCORD_ROSTER_BOT_TOKEN`, `DISCORD_ROSTER_GUILD_ID`, and the expected
   application ID without printing their values.
2. Call `GET /oauth2/applications/@me` using the bot token and confirm that the
   returned application ID equals `DISCORD_ROSTER_BOT_APPLICATION_ID`.
3. Issue `GET /guilds/{DISCORD_ROSTER_GUILD_ID}/members?limit=1` as the bot,
   with the `GUILD_MEMBERS` intent enabled in the Developer Portal.
4. Treat only a successful response with a valid JSON array as proof that the
   intended application can access the intended roster. A `401`, `403`, `404`,
   malformed response, or an unexpected application/guild identity is a hard
   stop; do not run or retry the backfill until an operator diagnoses it.
5. Discard the sampled member record after validating its schema. Log only
   non-sensitive evidence: application ID, guild ID, endpoint, status, count
   (0 or 1), timestamp, and tool revision.

An empty successful page proves access and is still valid for a temporarily
empty guild. It does not prove pagination, staging, assignment review, or
identity reconciliation; ALE-205 owns those controls. The actual import must
use `limit` up to 1000, the `after` Discord User ID cursor, response-driven
rate-limit handling, and no username/email reconciliation, as established by
ALE-203.

## Facts, repository findings, and assumptions

### Verified current Discord facts

- A bot user belongs to an application and authenticates with that application's
  bot token. Bot installation uses the OAuth2 bot authorization flow; the URL
  supports `guild_id`, `disable_guild_select`, and a requested permissions
  integer.
- Discord's **List Guild Members** endpoint is bot-authenticated and requires
  the `GUILD_MEMBERS` privileged intent. Privileged-intent HTTP restrictions
  apply independently of Gateway connections; the one-off HTTP roster reader
  does not open a Gateway connection.
- `GUILD_MEMBERS` must be enabled in the Developer Portal. Discord's currently
  documented access-review threshold is 10,000 unique users across visible
  servers, not a count of members in the DHC guild. Applications that have
  received privileged-intent review must reapply for continued access annually.
- A guild member entry contains the Discord User object, including the User ID;
  names and nicknames are mutable presentation metadata. The endpoint paginates
  with `after` and supports a `limit` up to 1000.

### Verified repository facts

- The repository currently configures only `DISCORD_CLIENT_ID`,
  `DISCORD_CLIENT_SECRET`, a callback URI, and a Discord webhook. It has no
  roster bot token, roster guild ID, roster script, or bot configuration.
- Production secrets are currently sourced through `fnox.toml` and 1Password.
  The new roster names are intentionally an operational contract until ALE-205
  introduces the task that consumes them.
- Per ADR 0009 and ALE-203, the interactive OAuth flow uses Assent, and Discord
  User ID/Assent `sub` is the provider-subject reconciliation key.

### Operational assumptions to validate

- DHC can create a separate application in a DHC-controlled Developer Team and
  has a guild administrator able to install it in the intended guild.
- The Developer Portal will permit `GUILD_MEMBERS` for the separate application
  or will state the approval path required. This must be proven by the portal
  and endpoint preflight, not inferred from the present guild population.
- The designated prefill environment can receive a narrowly scoped,
  auditable secret-store grant. The exact staging-write authorization remains
  for ALE-205 because this ticket creates no staging model.

## Contract for ALE-205

ALE-205 may implement the roster reader and prefill only after receiving an
execution record satisfying the required roster-access proof. It must accept
only `DISCORD_ROSTER_BOT_TOKEN` and `DISCORD_ROSTER_GUILD_ID` for Discord roster
access; it must reject use of the interactive OAuth client secret and must not
add a bot to that application.

Its operator workflow must preserve the separation established here: roster
data is read by the isolated bot, administrators use mutable names only to
recognize a person, and the selected Discord User ID is staged as the immutable
pending provider subject. The assignment review, one-to-one invariants, audit,
correction, first-use promotion, recovery, pagination implementation, and
retirement/correction-window timing remain explicitly in ALE-205's scope.

## Sources

- [Discord OAuth2 — Bot Users and Bot Authorization Flow](https://docs.discord.com/developers/topics/oauth2#bot-users)
- [Discord Gateway — Privileged Intents and HTTP Restrictions](https://docs.discord.com/developers/events/gateway#privileged-intents)
- [Discord Guild Resource — List Guild Members](https://docs.discord.com/developers/resources/guild#list-guild-members)
- [ALE-203 Discord OAuth and guild-roster capabilities](./ale-203-discord-oauth-guild-roster-capabilities.md)
- [ADR 0009 — Phoenix owns authentication](../adr/0009-phoenix-owns-authentication.md)
- [ADR 0010 — Authentication within Invitation Acceptance](../adr/0010-authentication-within-invitation-acceptance.md)
- [ADR 0013 — Onboarding owns Invitation issue and Invitation Acceptance](../adr/0013-onboarding-owns-invitation-issue-and-acceptance.md)
