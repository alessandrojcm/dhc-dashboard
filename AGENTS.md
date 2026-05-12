# PROJECT KNOWLEDGE BASE

**Generated:** 2026-05-12  
**Commit:** (latest)  
**Status:** Active migration from SvelteKit + Supabase to Phoenix + Ecto + Oban

## OVERVIEW

Dublin Hema Club dashboard: currently SvelteKit 2.x + Svelte 5 + Supabase + Stripe. Progressive migration to Phoenix + Ecto + Oban underway. Member management, workshops, payments, inventory.

**Phase 1**: Edge functions → Oban, then service layer → Phoenix API. SvelteKit consumes Phoenix via typed OpenAPI client.
**Phase 2** (future): Evaluate LiveView migration.

## STRUCTURE

```
dhc-dashboard/
├── apps/                      # Phoenix app (active)
│   └── phoenix/
│       ├── config/            # Ecto + Oban config per env
│       ├── lib/dhc/           # Ecto repo + contexts + Oban workers
│       │   ├── repo.ex        # Ecto Repo (connects to shared Postgres)
│       │   └── ...
│       ├── lib/dhc_web/       # Phoenix web layer (JSON API)
│       └── priv/
│           ├── repo/migrations/  # 11 baseline Ecto migrations (new source of truth)
│           └── api/              # OpenAPI spec (contract) — pending
├── packages/
│   └── api-client/            # Generated TypeScript client from OpenAPI spec
├── src/                       # Existing SvelteKit app (unchanged)
├── supabase/
│   ├── functions/             # Deno edge functions (BEING MIGRATED to Oban)
│   ├── migrations/            # SQL migrations (FROZEN — no new ones)
│   └── tests/                 # pgTAP database tests
├── e2e/                       # Playwright E2E tests
├── docs/
│   ├── adr/                   # Architecture Decision Records
│   └── agents/                # Agent documentation
├── CONTEXT.md                 # Domain glossary & architecture
└── Makefile                   # Root orchestration
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| Add DB mutation | `src/lib/server/services/` | CURRENT system — MUST use service layer |
| Add API endpoint | `src/routes/api/` | CURRENT system — uses `authorize()` |
| Add edge function | `supabase/functions/` | DEPRECATED — migrate to Oban instead |
| Add Supabase migration | `supabase/migrations/` | FROZEN — no new migrations |
| Add Phoenix Ecto context | `apps/phoenix/lib/dhc/<domain>/` | NEW — use Ecto schemas + changesets |
| Add Oban worker | `apps/phoenix/lib/dhc/<domain>/workers/` | NEW — use `Oban.Worker` |
| Add Phoenix API endpoint | `apps/phoenix/lib/dhc_web/controllers/` | NEW — write spec first, generate stub |
| Update OpenAPI spec | `apps/phoenix/priv/api/openapi.yaml` | NEW — spec is the contract |
| Generate TS client | Run `make api-gen` | NEW — from OpenAPI spec |
| Add E2E test | `e2e/` | Use helpers from `setupFunctions.ts` |
| Configure Sentry | `config/runtime.exs` (prod block) | Set `SENTRY_DSN` env var; integrates Phoenix, Oban, Logger |
| View ADRs | `docs/adr/` | Key architectural decisions |
| View domain glossary | `CONTEXT.md` | Domain language reference |

## MIGRATION NOTES

- **Database**: Ecto owns all schema changes. Supabase migrations frozen. Baseline migrations model current schema in Elixir code.
- **Auth**: Supabase Auth stays forever. Phoenix validates Supabase JWT. SvelteKit forwards JWT to Phoenix.
- **RLS**: No new policies. Existing ones removed when PostgREST is disabled.
- **Queues**: pgmq → Oban. Big-bang per-queue cutover. Discord → Email → Announcements → Stripe → Bulk Invite.
- **API design**: Spec-first with OpenAPI. Custom Mix task generates Phoenix controller stubs. TypeScript client generated from spec.
- **`.remote.ts` files**: The swap point. Rewrite from `executeWithRLS()` to `fetch(apiClient)` per domain.

## CRITICAL PATTERNS

See [docs/agents/critical-patterns.md](docs/agents/critical-patterns.md).

## ANTI-PATTERNS (FORBIDDEN)

See [docs/agents/anti-patterns.md](docs/agents/anti-patterns.md).

## COMMANDS

See [docs/agents/commands.md](docs/agents/commands.md).

## TECH STACK

See [docs/agents/tech-stack.md](docs/agents/tech-stack.md).

## SERVICES & ROLES

See [docs/agents/services-and-roles.md](docs/agents/services-and-roles.md).

## NOTES

See [docs/agents/notes.md](docs/agents/notes.md).

---

**See Also**: `CONTEXT.md`, `docs/adr/`, `src/lib/server/services/AGENTS.md`, `supabase/AGENTS.md`, `e2e/AGENTS.md`
