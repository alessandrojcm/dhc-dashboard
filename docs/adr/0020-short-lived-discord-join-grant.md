# Short-lived Discord Join Grant

**Status:** Accepted  
**Date:** 2026-08-18  
**Amends:** ADR-0014  
**Tags:** onboarding, discord, oauth, credentials, oban

## Context

ADR-0014 requires raw Discord identity data to be removed when an Invitation Acceptance Discord Continuation ends. Automatic server joining creates a narrower need: Discord's add-member operation requires the prospective member's `guilds.join` OAuth access token after the Member conversion commits. Calling Discord before conversion would couple membership acceptance to Discord availability, while putting the token in an Oban job would persist a credential outside the Discord domain.

## Decision

Invitation Acceptance may briefly retain one Discord access token in a Discord Join Grant. The grant is bound to the acceptance Attempt and Continuation, stores no refresh token, encrypts the access token at rest with `Plug.Crypto` and a purpose-specific salt derived from the application's existing secret key base, and is not usable for sign-in.

The Member conversion transaction inserts an Oban guild-join job only when a grant exists. The job contains the grant identifier, never token material. After the transaction commits, the worker resolves the new Member's Discord External Identity and asks the bot to add that Discord subject to the server. Added and already-member outcomes both succeed. Discord 401 and 403 outcomes are terminal and do not affect membership acceptance. Success, terminal authorization failure, invalid ciphertext, and token expiry null the encrypted token. Transient Discord failures retain it only for the worker's bounded retry window.

An hourly cleanup worker nulls and deletes grants whose token expiry has passed, including grants stranded by abandoned or failed acceptance flows. No backfill is attempted for existing Members.

## Consequences

- ADR-0014's credential-minimization posture is deliberately narrowed for this single post-commit operation; no general member OAuth credential store is introduced.
- Discord outages cannot roll back or block Invitation Acceptance.
- The database briefly contains encrypted access-token ciphertext, while Oban arguments and logs contain only opaque grant identifiers.
- Automatic joining is forward-looking. Missing existing Members are handled through Discord Doctor reconciliation rather than by retaining or reacquiring credentials.

## Considered options

- **Join before conversion commits.** Rejected because Discord availability would become part of membership acceptance and a rolled-back conversion could still leave someone in the server.
- **Store the access token in Oban arguments.** Rejected because job rows, telemetry, and inspection tools would become an additional credential store.
- **Store a refresh token.** Rejected because the one-shot join needs no renewable authority and would create long-lived credential custody.
