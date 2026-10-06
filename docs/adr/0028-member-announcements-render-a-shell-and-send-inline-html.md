# Member Announcements Render a Code-Authored Shell and Send Inline HTML

**Status:** Accepted  
**Date:** 2026-10-06  
**Tags:** email, resend, react-email, templates, broadcasts

## Context

The committee (president, committee coordinator, admin) needs to email every active member at once, optionally including inactive members, with a rich-text body and a live preview. ADR 0022 sends every Email Kind through a Resend-hosted template whose variables Resend interpolates. That does not hold up for a rich-text body: Resend limits a string variable to 2,000 characters, and its documentation does not say whether `{{{VAR}}}` values are HTML-escaped, so formatted HTML may not survive. Resend also offers no API that renders a template with variables for a preview.

## Decision

- **A Member Announcement is not an Email Kind.** Its React Email component (`packages/email-templates/emails/member-announcement.tsx`) is rendered once by `pnpm --filter @dhc/email-templates render:shells` into a committed shell, `apps/phoenix/priv/email_shells/member-announcement.html`, with literal `{{{SUBJECT}}}` / `{{{MESSAGE_HTML}}}` placeholders. Its inline style table goes to `member-announcement.styles.json` alongside it. A vitest drift test fails when the committed files no longer match a fresh render. The shell is never uploaded to Resend.
- **The body is a Tiptap JSON document, not HTML.** `Dhc.MemberAnnouncements.Document` renders a closed vocabulary (paragraph, headings 2–3, lists, blockquote, rule, hard break, bold/italic/underline/strike, http/https/mailto links) to inline-styled HTML plus a text alternative. It escapes every text node, so no HTML is ever parsed or sanitised. Anything outside the vocabulary is a 422.
- **Phoenix renders the preview.** `POST /api/member-announcements/preview` returns the exact HTML `create` would send, plus the recipient count. The dashboard shows it in a sandboxed iframe, so the preview cannot disagree with the email.
- **Recipients are BCC'd and sent through Resend's batch API.** The row freezes the rendered HTML, the text part and the lower-cased recipient addresses. `DeliveryWorker` puts 49 addresses in BCC per email (the club address is the visible `To`, which keeps each email under Resend's 50-recipient limit) and sends up to 100 emails per `POST /emails/batch`. Each batch request carries `Idempotency-Key: member-announcement:<id>:<batch>`. A few hundred members is one request.
- **Gated by the `member_announcements.send` capability** (officers).

## Consequences

- Editing the template requires `pnpm render:shells` and a Phoenix deploy; the template and the send path ship together.
- No per-recipient personalisation (BCC), and no unsubscribe handling (these are club-membership notices, not marketing broadcasts).
- Resend Broadcasts were not used: they would require syncing every member into Resend Contacts and Segments.
- The Mailpit dev adapter has no batch support, so dev delivers the same emails one by one.
