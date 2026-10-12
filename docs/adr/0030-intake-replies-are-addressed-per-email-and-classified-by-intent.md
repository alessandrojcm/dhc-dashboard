# Intake Replies Are Addressed per Email and Classified by Intent

**Status:** Accepted  
**Date:** 2026-10-12  
**Tags:** beginners-workshop, email, resend, typesafe, jev, automation

## Context

Most Beginners' Workshop Intake commands — decline, defer, withdraw, cancel with refund, refund a Carried Fee, resend the link, restore to the Waitlist — are run by the coordinator because a person asked by email. Every Transactional Email carries the same Reply-To, `contact@dublinhemaclub.com`, so these replies arrive mixed with all other club mail, and nothing in a reply ties it to the Intake Email it answers. The root domain's MX record already serves that inbox, and Intake Emails can quote the Intake link, which is a credential.

We want a reply to an Intake Email — and only those — to run the command the person asked for, using TypeSafe's Jev classifier, and otherwise to reach the inbox as it does today.

## Decision

- **Each Intake Email has its own reply address.** Its Reply-To is an address on a Resend receiving subdomain, bound to that one email and through it to the person and the Intake it was about (to the person alone for a Waitlist-tab notice with no Intake). The address is a credential, like the Intake link: never logged, never sent to Sentry or PostHog. Other Email Kinds keep the global Reply-To.
- **A Reply Action needs the address and the person's own email.** A reply leads to a Reply Action only if it was sent to a known reply address and its From matches the person's Waitlist email. Automated mail (auto-replies, out-of-office) never acts.
- **Jev classifies intent, not commands.** Jev receives only the person's new text, with quoted history removed and links redacted, plus the type of email answered — never an email address. It answers one Choice over the intents that could lead somewhere for this person now (can't make this date, leaving the Waitlist, wants a refund, wants to come back, lost or broken link, something else) and one Noul: is the person asking for their money back? Our code turns intent and Intake state into a command through `IntakePolicy` and runs it through `Dhc.BeginnersWorkshops.execute/3`, so the boundary's locked re-check still decides.
- **Money errs towards what can be undone.** When it is unclear whether a paid person wants their money back, the Reply Action is a Deferral, which can still become a refund later. A Reply Action never forfeits a fee; a paid person leaving the Waitlist without asking for their money back is left to the coordinator.
- **Intake intents act only on the Intake the email was about.** "Can't make it", refund and link requests act only while that Intake is still the person's open Intake. Intents about the person (leaving, coming back, refunding a held Carried Fee) act whichever email they answered.
- **Every Intake Reply is forwarded, exactly once.** It goes to the same inbox as today, rebuilt from Resend's received-email and attachments APIs (with the original attached as `.eml` when it cannot be rebuilt), with Reply-To set to the person and a subject tag naming what happened: done, needs you, or unrecognised. A failure at any step forwards it as needing the coordinator, so no reply is lost.
- **Intents are switched on by an offline eval.** Each intent is on or off in configuration. An eval over hand-labelled historic replies sets which intents start on and their confidence thresholds, stricter for intents that move money. An intent that is off behaves exactly as today. Thresholds and the pinned Jev model version are committed; the labelled emails never are.
- **We keep no email body.** Each reply's record holds its Resend id, the email it answered, Jev's answers and model version, and the outcome with its reason. It is deleted with the person on hard delete or the retention purge, and a deleted person's reply addresses stop resolving.
- **Coming back is acknowledged.** A restore from a reply sends a new "Back on the Waitlist" Intake Email; every other Reply Action already sends its Settlement notice.

## Considered Options

- **One shared reply address, matched by sender** — rejected: people reply from other addresses and aliases, and it loses which email they answered.
- **Matching `In-Reply-To` against stored Message-IDs** — rejected: mail clients drop or rewrite the header, and the email ledger stores no provider ids.
- **Classifying commands directly** — rejected: the right command depends on Intake state Jev should not see ("can't make it" is a Decline when unpaid and a Deferral when paid).
- **Suggest only, coordinator approves** — rejected in favour of eval-gated automation; every action is still visible in the inbox within minutes.
- **A per-intent shadow mode** — rejected: an intent with too little eval data simply stays off until a later eval.

## Consequences

- Replies to emails sent before this ships still reach the inbox as they do today.
- Reply addresses stay in people's inboxes indefinitely, so the receiving subdomain and the address format are hard to change later.
- TypeSafe receives reply text under its standard DPA, without zero data retention. Resend keeps received emails and offers no API to delete them.
- A wrong Reply Action is fixed with existing commands (Fast-track, restore, refund). A wrong refund cannot be undone, which is why money defaults to a Deferral.
- `Dhc.Email.Worker` must accept a Reply-To per email, and the boundary gains an actor for Reply Actions, which Intake history shows as done by email reply.
