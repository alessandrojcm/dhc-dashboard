# PROJECT KNOWLEDGE BASE

**Status:** Phoenix + Ecto + Oban migration complete

## Overview

Dublin Hema Club dashboard monorepo: the SvelteKit 2.x + Svelte 5 frontend lives in `apps/web`, alongside the Phoenix + Ecto + Oban backend in `apps/phoenix`. Root pnpm/mise commands delegate to the frontend workspace, which consumes Phoenix through the typed OpenAPI client in `packages/api-client`.

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
