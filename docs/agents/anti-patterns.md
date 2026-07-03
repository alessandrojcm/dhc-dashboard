# Anti-Patterns (Forbidden)

| Pattern | Why |
|---------|-----|
| `as any`, `@ts-ignore` | Type safety required |
| Direct Kysely in loaders | Must use `executeWithRLS()` |
| Skip service layer | ALL mutations through services |
| Direct Kysely in `.remote.ts` | MUST use service layer |
| Empty catch blocks | Log to Sentry |
| `$effect` when `$derived` works | Prefer derived runes |
| Bending production-aligned code to a divergent Ecto baseline | Fix the baseline to match production. Source of truth is the Supabase table, not the baseline. Example: `stripe_sync/repository.ex` writes `created_at:` (correct for prod); if the test harness fails because the baseline produced `inserted_at`, fix the baseline with `timestamps(inserted_at: :created_at)` — do NOT change the code to `inserted_at:`. See `docs/agents/critical-patterns.md` "Timestamp column names". |
| Plain `timestamps(type: :timestamptz)` on a ported Supabase table | Production uses `created_at`. Use `timestamps(type: :timestamptz, inserted_at: :created_at)`. Enforced by the `elixir-timestamps-missing-created-at` ast-grep rule (run via `mise run ast-lint`; see `sgconfig.yml`). |
