# ADR 0015: Separate Discord roster bot application

**Status:** Accepted  
**Date:** 2026-08-13  
**Deciders:** DHC engineering  
**Tags:** discord, onboarding, authentication, operations

## Context

ALE-202 requires an administrator-reviewed prefill of existing Members' Discord
identities.  ALE-203 established that the prefill reads the DHC guild roster as
a bot, requires the `GUILD_MEMBERS` privileged intent, and must reconcile only
by Discord User ID.  The existing Discord application is an OAuth client used
by the dashboard's interactive sign-in and acceptance flows.  A roster bot has
a distinct, short-lived operational purpose and a bearer token with access to
the guild member roster.

## Decision

DHC will provision a **separate, DHC-owned Discord application with one bot
user** for the existing-Member roster prefill.  It must not add a bot user to,
or share credentials with, the interactive Discord OAuth application.

The separate application keeps a roster-token compromise, privileged-intent
review, guild installation, rotation, and eventual retirement independent of
the OAuth client used by Members.  The bot has no ongoing product role: it is
installed only in the configured DHC guild, receives no guild permissions, and
is used only by the one-off roster prefill tooling.  DHC disables or removes
the bot and revokes/rotates its token once ALE-205's approved prefill and its
required correction window have completed.

The operational contract, including the exact environment names, installation
procedure, preflight evidence, and hand-off to ALE-205, is
[ALE-210 Discord roster bot provisioning contract](../research/ale-210-discord-roster-bot-provisioning-contract.md).

## Considered options

- **Extend the existing OAuth application with a bot user.** Rejected.  It
  couples a one-off privileged roster capability and its token lifecycle to the
  Member-facing OAuth client.  A bot-token incident or application-level
  privileged-intent decision would then disturb sign-in and Invitation
  Acceptance unnecessarily.
- **Use a human Discord account or a webhook.** Rejected.  Discord prohibits
  automation of standard user accounts, and a webhook URL cannot authenticate
  to the guild-member API.
- **Run a permanent guild bot.** Rejected.  The stated use is one-off prefill;
  retaining the bot would expand operational surface without a current domain
  requirement.

## Consequences

- The existing `DISCORD_CLIENT_ID` and `DISCORD_CLIENT_SECRET` remain owned by
  the interactive OAuth application and are never accepted by roster tooling.
- Continued privileged-intent access for the separate application requires the
  periodic Discord review applicable to the application's reach; its owner must
  keep that operational obligation with the prefill record.
- ALE-205 may start only after the preflight evidence defined by this ADR's
  contract has been recorded.
- This decision introduces no new domain term: the bot is an external
  operational integration, not a Member, Authentication, or Onboarding entity.
