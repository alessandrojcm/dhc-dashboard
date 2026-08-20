# Anti-Patterns (Forbidden)

| Pattern | Why |
|---------|-----|
| `as any`, `@ts-ignore` | Type safety required |
| Direct Kysely in loaders | Must use `executeWithRLS()` |
| Put domain mutation logic in SvelteKit | Domain mutations belong in Phoenix contexts; the frontend calls the generated API client |
| Wrap an existing generated Phoenix mutation in `.remote.ts` without adding a server-only boundary | Use generated TanStack mutation options directly for imperative operations |
| Direct Kysely in `.remote.ts` | Remote functions call Phoenix or an intentional server-only integration; they do not access the legacy database layer |
| Empty catch blocks | Log to Sentry |
| `$effect` when `$derived` works | Prefer derived runes |
| Bending production-aligned code to a divergent Ecto baseline | Fix the baseline to match production. Source of truth is the Supabase table, not the baseline. Example: `stripe_sync/repository.ex` writes `created_at:` (correct for prod); if the test harness fails because the baseline produced `inserted_at`, fix the baseline with `timestamps(inserted_at: :created_at)` — do NOT change the code to `inserted_at:`. See `docs/agents/critical-patterns.md` "Timestamp column names". |
| Plain `timestamps(type: :timestamptz)` on a ported Supabase table | Production uses `created_at`. Use `timestamps(type: :timestamptz, inserted_at: :created_at)`. Enforced by the `elixir-timestamps-missing-created-at` ast-grep rule (run via `mise run ast-lint`; see `sgconfig.yml`). |
| Hand-rolled Stripe API calls in domain code | Stripe calls must go through the generated Elixir client. Add the exact operation ID to both Stripe allow-lists, run `mise run stripe-gen`, and use `Dhc.Stripe.Operations.*`; do not bypass with `Dhc.Stripe.Client.request/1` unless debugging the generated client boundary itself. |
