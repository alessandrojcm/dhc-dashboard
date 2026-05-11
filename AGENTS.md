# PROJECT KNOWLEDGE BASE

**Generated:** 2026-02-10  
**Commit:** 4b44a4c  
**Branch:** feature/ale-79-migrate-charts-to-shadcn-charts

## OVERVIEW

Dublin Hema Club dashboard: SvelteKit 2.x + Svelte 5 + Supabase + Stripe. Member management, workshops, payments, inventory.

## STRUCTURE

```
dhc-dashboard/
├── src/
│   ├── routes/           # SvelteKit routes (public, dashboard, api, auth)
│   ├── lib/
│   │   ├── server/       # Server utilities, Kysely, auth
│   │   │   └── services/ # Domain-driven service layer (CRITICAL)
│   │   ├── components/   # UI components (shadcn-svelte)
│   │   └── schemas/      # Valibot validation schemas
│   └── database.types.ts # Auto-generated Supabase types
├── supabase/
│   ├── functions/        # Deno edge functions
│   ├── migrations/       # SQL migrations (timestamped)
│   └── tests/            # pgTAP database tests
├── e2e/                  # Playwright E2E tests
└── instructions/         # Architecture docs & migration plans
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| Add DB mutation | `src/lib/server/services/` | MUST use service layer |
| Add API endpoint | `src/routes/api/` | Delegate to service, use `authorize()` |
| Add form | Use Superforms + Valibot | Components in `src/lib/components/ui/form` |
| Add dashboard page | `src/routes/dashboard/` | Check RBAC in layout |
| Add edge function | `supabase/functions/` | Deno runtime, use `_shared/` |
| Add migration | `supabase/migrations/` | Run `pnpm supabase:types` after |
| Add E2E test | `e2e/` | Use helpers from `setupFunctions.ts` |

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

**See Also**: `src/lib/server/services/AGENTS.md`, `supabase/AGENTS.md`, `e2e/AGENTS.md`
