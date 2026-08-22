# Structure

```text
dhc-dashboard/
├── apps/
│   ├── web/                  # SvelteKit frontend workspace (@dhc/web)
│   │   ├── src/              # Routes, components, hooks, and app code
│   │   ├── static/           # Public assets
│   │   ├── e2e/              # Playwright tests
│   │   └── package.json      # Frontend dependencies and scripts
│   └── phoenix/              # Phoenix API and workers
│       ├── config/            # Ecto + Oban config per env
│       ├── lib/dhc/           # Ecto repo + contexts + Oban workers
│       │   ├── repo.ex        # Ecto Repo (connects to shared Postgres)
│       │   └── ...
│       ├── lib/dhc_web/       # Phoenix web layer (JSON API)
│       ├── lib/mix/            # Custom Mix tasks
│       │   └── tasks/          # gen.controllers, dhc.seed_members, etc.
│       ├── dev/                # Dev-only compile path (elixirc_paths(:dev))
│       │   ├── dev_seeds.ex    # Faker-backed seed runner (concurrent)
│       │   └── mix/tasks/      # seed.members, seed.waitlist, seed.committee_members
│       └── priv/
│           ├── repo/migrations/  # 11 baseline Ecto migrations (new source of truth)
│           └── api/              # OpenAPI spec (contract) — active
├── packages/
│   ├── api-client/              # Generated TypeScript client from OpenAPI spec
│   │   ├── openapi-ts.config.ts  # Config: reads spec, outputs src/client/
│   │   ├── src/
│   │   │   ├── index.ts          # Public API: SDK functions, types, config
│   │   │   ├── config.ts         # configureClient() + JWT getter setup
│   │   │   └── client/           # Auto-generated on pnpm install (gitignored)
│   │   └── package.json          # @dhc/api-client workspace package
│   └── email-templates/         # Code-authored transactional emails (@dhc/email-templates)
│       ├── emails/               # React Email components + metadata exports (ADR 0022)
│       ├── src/                  # Template metadata schema + kind→template registry
│       └── test/                 # Schema validation tests only (no render tests)
├── supabase/
│   ├── functions/             # Deno edge functions (BEING MIGRATED to Oban)
│   ├── migrations/            # SQL migrations (FROZEN — no new ones)
│   └── tests/                 # pgTAP database tests
├── e2e/                       # Playwright E2E tests
├── docs/
│   ├── adr/                   # Architecture Decision Records
│   └── agents/                # Agent documentation
├── CONTEXT.md                 # Domain glossary & architecture
├── .mise.toml                 # Tool versions + task runner (replaces Makefile)
└── .mise.local.toml           # Local mise overrides (gitignored)
```
