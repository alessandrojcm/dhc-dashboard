# Anti-Patterns (Forbidden)

| Pattern | Why |
|---------|-----|
| `as any`, `@ts-ignore` | Type safety required |
| Direct Kysely in loaders | Must use `executeWithRLS()` |
| Skip service layer | ALL mutations through services |
| Direct Kysely in `.remote.ts` | MUST use service layer |
| Empty catch blocks | Log to Sentry |
| `$effect` when `$derived` works | Prefer derived runes |
