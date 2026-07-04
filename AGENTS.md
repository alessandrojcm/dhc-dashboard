# PROJECT KNOWLEDGE BASE

**Status:** Active migration from SvelteKit + Supabase to Phoenix + Ecto + Oban

## Overview

Dublin Hema Club dashboard: currently SvelteKit 2.x + Svelte 5 + Supabase + Stripe. Progressive migration to Phoenix + Ecto + Oban underway. Member management, workshops, payments, inventory.

- **Phase 1**: Edge functions → Oban, then service layer → Phoenix API. SvelteKit consumes Phoenix via typed OpenAPI client.
- **Phase 2** (future): Evaluate LiveView migration.

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

`CONTEXT.md`, `docs/adr/`, `src/lib/server/services/AGENTS.md`, `supabase/AGENTS.md`, `e2e/AGENTS.md`

<!-- graymatter:instructions:begin — managed by `graymatter init`; edits inside this block are overwritten -->
## Memory (GrayMatter)

This project has persistent agent memory via the `graymatter` MCP tools:

- `memory_search` (`agent_id`, `query`) — call at the **start of a task** when prior context might matter.
- `memory_add` (`agent_id`, `text`) — call whenever you learn something **durable**: user preferences, decisions, conventions, gotchas.
- `memory_reflect` (`action`, `agent`, `text`/`target`) — update or forget stale facts. ⚠ takes `agent`, not `agent_id`.
- `checkpoint_save` / `checkpoint_resume` (`agent_id`) — snapshot/restore session state before major refactors or across restarts.

Use a stable `agent_id` of the form `<project>-<role>` (e.g. `myapp-backend`). Store conclusions, not conversation logs. Err on the side of remembering.
<!-- graymatter:instructions:end -->
