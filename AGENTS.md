# PROJECT KNOWLEDGE BASE

**Status:** Phoenix + Ecto + Oban migration complete

## Overview

Dublin Hema Club dashboard monorepo: the SvelteKit 2.x + Svelte 5 frontend lives in `apps/web`, alongside the Phoenix + Ecto + Oban backend in `apps/phoenix`. Root pnpm/mise commands delegate to the frontend workspace, which consumes Phoenix through the typed OpenAPI client in `packages/api-client`.

Invitation Acceptance is owned by `Dhc.Onboarding.Acceptance` (GH-507) behind an **opaque handle** — the signed `_dhc_onboarding_acceptance` cookie value — and every browser-facing operation returns a closed safe view whose `state` is the discriminator; never return an Ecto schema, attempt id, operation token, confirmation token, or provider subject from it. Every authoritative read of Continuation/Attempt/Invitation/Claim rows goes through `Acceptance.Locked` (principal advisory → subject advisory → Continuation → Attempt → Invitation → Claims): add a transition inside a `with_locked`/`lock!` block rather than writing a new `FOR UPDATE` query. Synchronous `submit_payment/2`, explicit `retry/1`, and worker `recover/1` converge on the private `progress/2` (lease in one transaction, Stripe outside it, `owned_fence!/1` before every write) — do not add a second Stripe progression path. Pricing is handle-bound too (`preview_pricing/2`, `GET /onboarding/invitation-acceptance/pricing`, `paymentReady` only per ADR-0019): the public Invitation id is never workflow authority, so do not reintroduce an `/invitations/:id/pricing`-style read. `Dhc.Onboarding` keeps only Invitation-level operations. See the Invitation Acceptance row in `docs/agents/where-to-look.md`.

JavaScript/TypeScript linting uses the shared root Oxlint config through the `apps/web` and `packages/api-client` workspace scripts; formatting uses Oxfmt from `apps/web`. Root `pnpm` and mise tasks delegate to those workspace scripts.

Phoenix `mix precommit` runs `hex.audit` before dependency-provided Mix tasks; under the pinned Mix version, running Credo or Reach first unloads the archived Hex task from the current process.

Dev data can include pending direct member invitations through `mise run seed-invitations [count]`; see the Seeds section in `docs/agents/commands.md` for all seed tasks.

Invitation pricing tiers use backend-applied Stripe coupon IDs, not customer-facing promotion codes; see the invitation pricing tier note in `docs/agents/notes.md` for coupon configuration and E2E conventions.

## Navigation

- Structure: [docs/agents/structure.md](docs/agents/structure.md)
- Where to look: [docs/agents/where-to-look.md](docs/agents/where-to-look.md)
- Migration notes: [docs/agents/migration-notes.md](docs/agents/migration-notes.md)
- Critical patterns: [docs/agents/critical-patterns.md](docs/agents/critical-patterns.md)
- Anti-patterns: [docs/agents/anti-patterns.md](docs/agents/anti-patterns.md)
- Commands: [docs/agents/commands.md](docs/agents/commands.md)
- Tech stack: [docs/agents/tech-stack.md](docs/agents/tech-stack.md)
- Services & roles: [docs/agents/services-and-roles.md](docs/agents/services-and-roles.md)
- Notes: [docs/agents/notes.md](docs/agents/notes.md)
- Visual previews: [docs/agents/visual-previews.md](docs/agents/visual-previews.md)
- Frontend design system: [design-system/dublin-hema-club/MASTER.md](design-system/dublin-hema-club/MASTER.md)

## Agent skills

- Issue tracker: Linear issues via `linctl`; see [docs/agents/issue-tracker.md](docs/agents/issue-tracker.md).
- Triage labels: canonical labels/status strings; see [docs/agents/triage-labels.md](docs/agents/triage-labels.md).
- Domain docs: single-context monorepo with `CONTEXT.md` and `docs/adr/`; see [docs/agents/domain.md](docs/agents/domain.md).

## See also

`CONTEXT.md`, `docs/adr/`, `supabase/AGENTS.md`, `e2e/AGENTS.md`
