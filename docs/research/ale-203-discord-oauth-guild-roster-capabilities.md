# ALE-203 — Discord OAuth and guild-roster capabilities

**Research date:** 2026-08-13  
**Question:** What do the current Discord and Assent contracts permit and require for carrying a verified Discord user through Invitation Acceptance and importing the guild roster for existing-Member prefill?

## Conclusion

The installed Assent strategy already provides the secure Discord authorization-code exchange needed to verify an account. It returns Discord's User ID as `sub`, which is also the User ID contained in a guild roster entry. DHC can therefore bind both new Invitation Acceptances and administrator-reviewed existing-Member assignments by the same provider subject.

The current controller cannot be reused unchanged. Every successful callback currently finishes either Discord sign-in or authenticated account linking and then redirects to the dashboard. Invitation Acceptance needs a distinct OAuth purpose that preserves the invitation context, returns a short-lived verified Discord assertion to the acceptance workflow, and does not establish a Session.

Bulk roster import needs a Discord bot token, the guild ID, and the `GUILD_MEMBERS` privileged intent. DHC already operates a bot externally, while the repository currently configures only the interactive OAuth client and Discord webhook—not that bot's token or guild ID. ADR-0015 requires a one-off roster script to receive temporary audited access to the existing bot token. The roster must be used to stage assignments by Discord User ID; username, global display name, guild nickname, and email are not safe reconciliation keys.

## Installed OAuth contract

The repository pins Assent `0.3.1` and configures `Assent.Strategy.Discord` with:

- `DISCORD_CLIENT_ID`
- `DISCORD_CLIENT_SECRET`
- one callback URI
- `code_verifier: true`

The local start path calls `authorize_url/1`, stores Assent's returned `session_params` in the Phoenix session, and redirects to Discord. The callback restores those parameters and calls `callback/2`. This preserves Assent's OAuth state and PKCE verifier across the redirect (`apps/phoenix/config/runtime.exs:105-110`; `apps/phoenix/lib/dhc_web/controllers/auth_session_controller.ex:76-105`).

Assent `0.3.1` requests `identify email` by default, calls `/users/@me`, and normalizes these claims:

| Discord User field | Assent claim | Correct use |
|---|---|---|
| `id` | `sub` | Provider subject and reconciliation key |
| `username` | `preferred_username` | Mutable display metadata |
| `email` | `email` | Mutable metadata; available because of the `email` scope |
| `verified` | `email_verified` | Metadata about the reported Discord email |
| avatar fields | `picture` | Mutable display metadata |

The installed strategy does not normalize a separate `username` claim. Current DHC metadata accepts both `preferred_username` and `username`, but Assent `0.3.1` populates `preferred_username` (`apps/phoenix/lib/dhc/auth.ex:189-204`).

Discord documents `id` as the User object's snowflake identifier. Existing DHC research establishes the end-to-end key equivalence from Discord User ID to Assent `sub` and `external_identities.provider_subject`; Discord does not publish a stronger formal immutability warranty. Snowflakes must remain strings across JSON and JavaScript boundaries.

The final subject-only flow needs only the `identify` scope to retrieve the User ID and username. The `email` scope is required only while DHC retains the current verified-email reconciliation fallback or otherwise wants Discord email as metadata; Invitation verification remains independent of Discord email.

Sources:

- [Discord OAuth2 scopes and state](https://docs.discord.com/developers/topics/oauth2)
- [Discord User object and Get Current User](https://docs.discord.com/developers/resources/user#get-current-user)
- [Assent 0.3.1 Discord strategy source](https://github.com/pow-auth/assent/blob/v0.3.1/lib/assent/strategies/discord.ex)
- [Prior DHC key-equivalence research](./ale-155-discord-identity-portability.md)

## Gap in the current callback

The current callback has only two successful meanings:

1. find or create an External Identity through Discord sign-in and establish a Session; or
2. link Discord to a Principal identified by an existing authenticated Session.

Both paths redirect to the dashboard (`apps/phoenix/lib/dhc_web/controllers/auth_session_controller.ex:90-151`). A prospective Member has no Principal before Invitation Acceptance, and acceptance must not establish a Session. A prospective principal UUID on the Invitation is not itself a Principal and cannot be used with the existing linking function.

The reusable portion is therefore the protocol adapter:

- Assent authorization URL generation;
- state and PKCE session parameters;
- callback code exchange;
- normalized User claims.

The acceptance-specific portion must be new:

- record the OAuth purpose as Invitation Acceptance rather than sign-in or authenticated linking;
- bind the OAuth start and callback to the already-verified Invitation;
- reject cross-invitation replay and expired continuation state;
- return or retain a short-lived assertion containing at least the verified `sub` and username metadata;
- avoid calling `Auth.sign_in_with_discord/1` and avoid creating a Session;
- consume the assertion when the acceptance workflow atomically creates the Principal and External Identity.

Whether this assertion is a signed continuation or a durable row is a downstream design decision. No Discord access or refresh token is required after `/users/@me` has produced the claims needed for identity binding.

## Guild-roster import contract

Discord exposes `GET /guilds/{guild.id}/members` for bulk roster reads. The endpoint:

- is authenticated as a bot;
- requires the `GUILD_MEMBERS` privileged intent;
- returns Guild Member objects containing a Discord User object;
- accepts `limit` from 1 to 1000, with a documented default of 1;
- paginates with the `after` Discord User ID cursor.

The Guild Member contains the same User `id` used by `/users/@me`, plus mutable presentation data such as username, global display name, guild nickname, roles, and join time. It does not provide the Member's Discord email for bulk reconciliation. Discord email is available only to that user-authorized OAuth flow with the `email` scope.

Discord's endpoint documentation states the privileged-intent requirement; it does not state that `View Channels`, `Create Instant Invite`, or a separate “Read Member List” guild permission is required for this list operation. The bot must belong to the guild and its application must have the intent enabled. Privileged-intent approval rules depend on the Discord application's verification and guild reach, not on the DHC guild having 100 members.

Rate limits are dynamic. The script must inspect Discord's rate-limit response headers and honor `429` responses and `retry_after`. It must not hard-code a global request rate or an arbitrary inter-page delay.

Sources:

- [List Guild Members](https://docs.discord.com/developers/resources/guild#list-guild-members)
- [Guild Member object](https://docs.discord.com/developers/resources/guild#guild-member-object)
- [Privileged intents](https://docs.discord.com/developers/events/gateway#privileged-intents)
- [Discord rate limits](https://docs.discord.com/developers/topics/rate-limits)
- [Discord OAuth2 `email` scope](https://docs.discord.com/developers/topics/oauth2#shared-resources-oauth2-scopes)

## Safe existing-Member prefill

The technically safe prefill sequence is:

1. Fetch every guild roster page with the bot token.
2. Present usernames, global names, and guild nicknames to an administrator for human identification only.
3. Store the selected guild entry's Discord User ID as the pending provider subject, together with a username snapshot for review.
4. Enforce that one pending or accepted Discord User ID cannot target multiple Principals and one Principal cannot have multiple pending or accepted Discord identities.
5. On first Discord OAuth login, compare Assent `sub` with the pending provider subject.
6. Atomically promote the matching assignment to External Identity and establish the eligible Session.

Username-only prefill is not sufficient. Discord documents `username` as non-unique across the platform, and username, global display name, and guild nickname can change. An administrator can use those values to recognize a person, but OAuth reconciliation must use the Discord User ID selected from the roster.

The administrator mapping is an assignment of login authority. A wrong mapping can cause one person to reach another Member's Principal. The downstream design must therefore define review, audit, uniqueness, correction, first-use, and post-use recovery controls.

## Repository capability audit

Present:

- Discord OAuth client ID, client secret, callback URI, and PKCE configuration (`apps/phoenix/config/runtime.exs:105-110`)
- OAuth start and callback protocol adapter (`apps/phoenix/lib/dhc_web/controllers/auth_session_controller.ex:53-151`)
- External Identity uniqueness by provider subject and by Principal/provider
- `Req` for an eventual HTTP roster client
- Discord webhook configuration for announcements

Not present in repository configuration or the current integration:

- Discord bot token
- DHC guild ID
- guild-roster client or import script
- pending administrator assignment model
- acceptance-specific Discord OAuth purpose and callback completion

A webhook URL cannot authenticate guild-roster API requests. Reusing an existing bot or provisioning a separate application is a design and operations choice, not a protocol requirement. ADR-0015 resolves that choice for DHC by reusing its existing bot only as the credential for a separate one-off roster script.

## Constraints for downstream tickets

1. **Invitation Acceptance:** reuse Assent's protocol exchange, not the current sign-in completion behavior.
2. **Identity key:** persist and compare Discord User ID/Assent `sub`; keep username as mutable metadata.
3. **Scopes:** `identify` is sufficient for the target subject-only contract; retain `email` only for an explicitly temporary or metadata purpose.
4. **No premature Session:** the acceptance OAuth callback must not authenticate a Principal that does not exist yet.
5. **Roster prerequisites:** make the existing bot token and guild ID available through the controlled task environment, verify that bot is installed in the DHC guild, and enable `GUILD_MEMBERS` before the prefill script runs.
6. **Roster pagination:** request up to 1000 entries, follow the `after` cursor, and obey response-driven rate limits.
7. **Administrator authority:** the script must stage the selected Discord User ID, not infer authority from username or email.
8. **Data minimization:** retain only the provider subject and display metadata required for review and support unless a later decision justifies more guild data.

## Open decisions

- Signed versus durable invitation-bound Discord continuation.
- Exact pending-assignment persistence, audit, and correction model.
- Script input/output and administrator review ergonomics.
- Whether and when to remove the `email` OAuth scope with the email-based login fallback.
- Operational verification that the intended Discord application can enable `GUILD_MEMBERS` and is installed in the DHC guild.
