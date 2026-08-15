# ALE-210 — Existing Discord bot roster-access contract

**Decision date:** 2026-08-13  
**Amended:** 2026-08-15
**Status:** Superseded in part by ADR-0019's 2026-08-15 amendment
**Scope:** Prove and temporarily expose the minimum Discord capability required
to read the DHC guild roster for the one-off existing-Member prefill. This
document does not implement a bot, a roster client, persistence, or the prefill.

> **Supersession note (2026-08-15):** The endpoint, pagination, privileged-intent,
> and credential-safety findings remain valid. The in-app preflight execution,
> capture authorization, encrypted package, digest, and receipt design is
> superseded. The migration now uses `scripts/discord-roster-export.mjs` with
> `DISCORD_BOT_TOKEN` and `DISCORD_GUILD_ID`, writes restricted plain
> `roster.json` out of band, and leaves only selected staged assignments plus
> their audit history in the application database.

## Decision summary

Reuse the existing DHC-owned Discord bot already installed in the target guild.
Run roster access as a separate, one-shot administrative script authenticated
with that bot's token. Do not create another Discord application, add roster
logic to the bot's normal runtime, or use the interactive OAuth client secret.

The script's only Discord operation is
`GET /guilds/{guild.id}/members` during the controlled prefill. Reusing the bot
identity does not make roster synchronization a permanent service and does not
change the bot's established product role.

## Operational contract

### Ownership and credentials

| Item | Contract |
| --- | --- |
| Discord ownership | The existing bot application must be DHC-controlled, already installed in the intended guild, and recoverable by at least two current DHC administrators. Record its application ID and operational owner. |
| Interactive OAuth client | `DISCORD_CLIENT_ID` and `DISCORD_CLIENT_SECRET` remain Member-facing OAuth credentials. The roster script never accepts them as roster authentication. |
| Existing bot token | Inject the existing token into the one-shot environment under the task-local name `DISCORD_ROSTER_BOT_TOKEN`. This is an access alias, not a second bot or a new persistent copy. Never commit, print, log, persist, or expose it to browser code. |
| Guild configuration | Supply `DISCORD_ROSTER_GUILD_ID` and expected `DISCORD_ROSTER_BOT_APPLICATION_ID` as opaque strings. The latter is required for the preflight identity check. |
| Temporary access | The ALE-205 executor receives audited access only for the approved execution window. The dashboard runtime, browser, CI, and ordinary developer environments do not receive the bot token. Revoke executor access and destroy the one-shot environment after the correction window. |

The capture command additionally requires
`DISCORD_ROSTER_EXECUTION_PROFILE=approved-one-shot`, an immutable
`DISCORD_ROSTER_TOOL_REVISION`, and `DISCORD_ROSTER_EXECUTION_ID` naming a
current, unconsumed database authorization for the operator, guild,
application, and revision. It derives the actor from that authorization after
rechecking the operator's current Member-administration role; callers do not
self-assert an actor ID.

Adding these task-local names to Phoenix runtime configuration is prohibited;
they belong only to the operator-invoked roster tooling.

### Existing application and guild preflight

Before capture, the DHC operations owner must:

1. confirm that the existing bot application's ID and owner match the approved
   operational record;
2. confirm that the bot is installed in `DISCORD_ROSTER_GUILD_ID`;
3. enable the **Server Members Intent** (`GUILD_MEMBERS`) in the existing
   application's Developer Portal settings, obtaining Discord approval first if
   the application's current verification/reach requires it;
4. confirm that no guild permission such as `ADMINISTRATOR`, `MANAGE_GUILD`, or
   `VIEW_CHANNELS` is being added for roster export—the list-members endpoint is
   gated by bot membership and the privileged intent, not those permissions;
5. record whether the bot's established runtime also needs `GUILD_MEMBERS`, so
   operations knows whether the intent may be disabled after the migration.

Discord's portal state is authoritative for privileged-intent approval. A
small DHC guild does not by itself prove that an application serving other
guilds may enable the intent without review.

### Execution environment

Roster access runs only as a one-shot, operator-invoked administrative task in
an approved production-capable environment. It must not run in a Phoenix web
request, the existing bot process, an Oban worker, browser, CI job, cron, or an
ordinary developer environment.

The task receives a narrow audited secret-store grant for the existing bot token
and guild configuration plus only the DHC access ALE-205 requires for staged
assignments. It must not inherit either the bot runtime's or Phoenix runtime's
general secret bundle. Its execution record contains the operator, timestamp,
application ID, guild ID, tool revision, and preflight result, but never the bot
token or complete roster data.

### Required roster-access proof

Access is not approved until a credentialed preflight succeeds from the same
one-shot environment intended for capture. The preflight must:

1. load `DISCORD_ROSTER_BOT_TOKEN`, `DISCORD_ROSTER_GUILD_ID`, and
   `DISCORD_ROSTER_BOT_APPLICATION_ID` without printing their values;
2. call `GET /oauth2/applications/@me` with `Authorization: Bot <token>` and
   confirm the returned application ID;
3. call
   `GET /guilds/{DISCORD_ROSTER_GUILD_ID}/members?limit=1` with the Server
   Members Intent enabled;
4. treat `401`, `403`, `404`, malformed data, or an unexpected application or
   guild identity as a hard stop;
5. discard the sampled member after schema validation and record only
   application ID, guild ID, endpoint, status, count, timestamp, and tool
   revision.

The actual capture requests up to 1000 entries per page, follows the opaque
`after` Discord User ID cursor, and obeys response rate-limit headers and each
`429` `retry_after`. It reconciles by Discord User ID only.

## Cleanup contract

After the approved prefill, final report, correction window, and recovery
hand-off:

1. revoke the executor's access to the existing bot token;
2. destroy the one-shot environment and delete the restricted roster package;
3. retain only the receipts, selected staged assignments, and required audit
   records defined by ADR-0016 and ADR-0017;
4. disable `GUILD_MEMBERS` if the existing bot's established role does not use
   it and Discord permits the change;
5. leave the existing bot installed and operating in its established role; and
6. rotate its token only under normal credential policy or suspected exposure,
   coordinating any rotation with the existing bot runtime.

A later roster capture requires a new approved execution and preflight. The
existing bot's continued presence is not standing authorization for periodic
roster synchronization.

## Repository facts and implementation boundary

- The repository currently configures the interactive OAuth client and a
  Discord webhook, but it does not configure the externally operated DHC bot's
  token, guild ID, or roster script.
- The roster script may consume the bot token through controlled operations
  tooling without adding that token to `runtime.exs`, `fnox.toml`, OpenAPI,
  Oban arguments, or frontend state.
- Discord User ID from the guild roster is the same provider-subject fact as
  Assent's OAuth `sub`; mutable names assist human review only.
- ALE-205 owns capture, staging, independent review, correction, first-use
  promotion, pagination, and the final cleanup evidence.

## Sources

- [Discord OAuth2 — Bot Users and Bot Authorization Flow](https://docs.discord.com/developers/topics/oauth2#bot-users)
- [Discord Gateway — Privileged Intents and HTTP Restrictions](https://docs.discord.com/developers/events/gateway#privileged-intents)
- [Discord Guild Resource — List Guild Members](https://docs.discord.com/developers/resources/guild#list-guild-members)
- [Discord API rate limits](https://docs.discord.com/developers/topics/rate-limits)
- [ALE-203 Discord OAuth and guild-roster capabilities](./ale-203-discord-oauth-guild-roster-capabilities.md)
- [ADR 0015 — Reuse the existing Discord bot for roster prefill](../adr/0015-reuse-existing-discord-bot-for-roster-prefill.md)
