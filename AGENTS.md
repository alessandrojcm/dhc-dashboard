# PROJECT KNOWLEDGE BASE

**Status:** Phoenix + Ecto + Oban migration complete

## Overview

Dublin Hema Club dashboard monorepo: the SvelteKit 2.x + Svelte 5 frontend lives in `apps/web`, alongside the Phoenix + Ecto + Oban backend in `apps/phoenix`. Root pnpm/mise commands delegate to the frontend workspace, which consumes Phoenix through the typed OpenAPI client in `packages/api-client`.

Frontend linting uses Oxlint and formatting uses Oxfmt from `apps/web`; root `pnpm` and mise tasks delegate to those workspace scripts.

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

## Agent skills

- Issue tracker: Linear issues via `linctl`; see [docs/agents/issue-tracker.md](docs/agents/issue-tracker.md).
- Triage labels: canonical labels/status strings; see [docs/agents/triage-labels.md](docs/agents/triage-labels.md).
- Domain docs: single-context monorepo with `CONTEXT.md` and `docs/adr/`; see [docs/agents/domain.md](docs/agents/domain.md).

## See also

`CONTEXT.md`, `docs/adr/`, `supabase/AGENTS.md`, `e2e/AGENTS.md`
