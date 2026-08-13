# ADR 0015: Reuse the existing Discord bot for roster prefill

**Status:** Accepted  
**Date:** 2026-08-13  
**Deciders:** DHC engineering  
**Tags:** discord, onboarding, authentication, operations

## Context

ALE-202 requires an administrator-reviewed prefill of existing Members' Discord
identities. ALE-203 established that the prefill reads the DHC guild roster as
a bot, requires the `GUILD_MEMBERS` privileged intent, and must reconcile only
by Discord User ID. DHC already operates a bot in the target guild. The prefill
therefore needs a controlled one-off roster export, not another Discord
application or a new long-running bot service.

## Decision

DHC will reuse its **existing DHC-owned Discord bot** to authenticate the
one-off existing-Member roster export. The export remains an operator-invoked
administrative script; it is not added to the bot's normal runtime and does not
turn roster capture into a recurring product capability.

The script receives narrowly scoped, audited access to the existing bot token
under a task-local roster credential name. It must not receive or use the
interactive OAuth client secret, and the token must not be copied into the
dashboard runtime, browser, CI, logs, database, or review package. Before
capture, an execution preflight proves the bot application identity, target
guild membership, and access to `GET /guilds/{guild.id}/members` with the
`GUILD_MEMBERS` intent enabled. The endpoint requires no guild permissions.

After the approved prefill and correction window, DHC revokes the script
executor's secret access and deletes its execution environment and roster
package. The existing bot remains installed for its established role. DHC may
disable `GUILD_MEMBERS` afterward when that role does not require it; token
rotation is required only by the normal credential policy or suspected
exposure, and must be coordinated with the existing bot runtime.

The operational contract, including the exact environment names, existing-bot
access requirements, preflight evidence, and hand-off to ALE-205, is
[ALE-210 existing-bot roster access contract](../research/ale-210-existing-bot-roster-access-contract.md).

## Considered options

- **Provision a separate temporary bot application.** Rejected because DHC
  already operates a suitable bot in the target guild. A second application,
  installation, ownership path, token, and retirement procedure add operational
  work without changing the reviewed assignment or first-use OAuth guarantees.
- **Run roster export inside the existing bot runtime.** Rejected. Reusing the
  bot identity does not justify coupling a one-off migration to the permanent
  process; the script runs separately with temporary audited token access.
- **Use a human Discord account or a webhook.** Rejected.  Discord prohibits
  automation of standard user accounts, and a webhook URL cannot authenticate
  to the guild-member API.
- **Run periodic roster synchronization.** Rejected. Guild presence is not an
  ongoing identity or access assertion, and recurring capture would expand the
  retained operational surface without a domain requirement.

## Consequences

- Existing OAuth client credentials remain owned by interactive sign-in and are
  never accepted by roster tooling; the existing bot token is a distinct bearer
  credential even if both identities are managed by the same Developer Team.
- Enabling `GUILD_MEMBERS` changes the existing bot application's privileged
  access posture, so its owner must record the portal state and any approval
  obligation before capture.
- ALE-205 may start only after the preflight evidence defined by this ADR's
  contract has been recorded.
- This decision introduces no new domain term: the bot and export script are
  external operational integrations, not Member, Authentication, or Onboarding
  entities.
