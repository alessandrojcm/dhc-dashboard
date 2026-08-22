# Code-Authored Templates Synced to Resend-Hosted Templates

**Status:** Accepted  
**Date:** 2026-08-22  
**Tags:** email, resend, react-email, templates, ci-cd

## Context

Loops hosts transactional email templates in its dashboard: content and subject/sender metadata are invisible to the repository, unreviewable, and unauditable by agents. Migrating to Resend is the moment to flip template ownership. Resend offers two send models: dashboard-hosted templates (`template: {id, variables}`) or per-send inline `html`. Resend also supports authoring templates as React Email components and uploading them programmatically (official `resend` CLI; Templates API with stable aliases; draft→publish lifecycle with version history).

## Decision

Each Email Kind is authored as a React Email component in a new `packages/email-templates` workspace package. The component file also declares its Template metadata — default subject, default sender, declared typed variables (`string | number`, optional fallback) — making TypeScript the single schema authority for what each Kind requires. The Elixir side keeps only its generic string|number validation; Resend enforces per-template variable contracts at send time.

Templates remain hosted at Resend. A sync pipeline renders components to HTML and uploads them via the official CLI/API:

- Pull requests upload drafts only; merging to main publishes. Publishing therefore gates on review plus required checks, never on an arbitrary push.
- Templates carry a stable alias derived mechanically from the Email Kind (kebab-case). Sends address `template.id` by that alias, so no kind→ID configuration map or env-var indirection exists at runtime.
- Dashboard edits to templates are drift; the next sync overwrites them. Resend's version history is the recovery mechanism.

The cutover from Loops is a single global adapter flip. Resend does not provide a sandbox that can exercise production recipients, and no staging environment exists, so auth-critical delivery is verified directly during a quiet production window before the remaining flows.

## Consequences

- Template changes deploy through git review like all other code; agents can read and write templates.
- The provider's template store remains part of the production path: a future provider migration must re-upload templates there. Accepted in exchange for hosted rendering, server-side variable interpolation/escaping, and zero rendering machinery in Elixir.
- Non-prod environments keep receiving a JSON summary of Kind + data variables in Mailpit rather than rendered HTML; visual previews happen through React Email's local preview server during authoring.
- A typo'd alias surfaces as a send-time validation error; mitigated by the compile-time Email Kind whitelist plus a check asserting every whitelisted Kind has a published template.

## Considered options

- **Recreate templates in Resend's dashboard.** Rejected: closest to today's shape but keeps content invisible to the repo and would be throwaway work once code ownership landed.
- **App-shipped HTML** — render artifacts in-repo and send inline `html` per send. Rejected: makes the provider pure transport, but drags placeholder interpolation and HTML escaping into Elixir, ships rendered blobs alongside the Phoenix release, and forfeits Resend's draft/publish/versioning machinery.
