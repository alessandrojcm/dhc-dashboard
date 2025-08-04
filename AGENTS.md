# AGENTS.md - Essential Guide for Agentic Coding

## Commands
- **Test single file**: `pnpm test:e2e tests/specific-test.spec.ts` or `pnpm test:unit src/path/to/test.test.ts`
- **Lint/Format**: `pnpm lint` (check) | `pnpm format` (fix)
- **Type check**: `pnpm check`
- **Dev setup**: `pnpm supabase:start` → `pnpm supabase:functions:serve` → `pnpm dev` (in order)
- **DB types**: `pnpm supabase:types` (after schema changes)

## Code Style (from .cursor/rules/supabase.mdc)
- **Components**: kebab-case (`my-component.svelte`)
- **Svelte**: Use Svelte 5 syntax with runes (`$state`, `$derived`, `$props`)
- **Database**: Supabase client for queries, Kysely for mutations via `executeWithRLS()`
- **Forms**: Always use superforms + form components in `src/components/ui/form`
- **Money**: dinero.js | **Dates**: day.js | **State**: TanStack Query
- **Imports**: TypeScript strict, semantic HTML, minimize client components

## Error Handling
- Implement comprehensive error handling with Sentry logging
- API responses: `{success: true, [resource]: data}` format
- Use `makeAuthenticatedRequest()` helper for E2E tests

## Testing
- TDD: Write tests first, verify they fail, then implement
- E2E requires all 3 services running (supabase → functions → dev)
- Unique test data: `admin-${Date.now()}-${Math.random().toString(36).substring(2, 15)}@test.com`
