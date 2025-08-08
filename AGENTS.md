# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a SvelteKit application for managing a Historical European Martial Arts club (Dublin Hema Club, DHC for short)
dashboard. It handles member management,
workshop coordination, payment processing, and subscription management using Supabase as the backend and Stripe for
payments.

## Development Commands

### Environment Setup

- `pnpm supabase:start` - Start local Supabase development instance (REQUIRED FIRST)
- `pnpm supabase:functions:serve` - Start Supabase edge functions (REQUIRED for E2E tests)
- `pnpm dev` - Start development server (uses Vite with --host flag)
- `pnpm supabase:reset` - Reset and seed the local database

**IMPORTANT**: For E2E testing, ALL THREE services must be running in this order:

1. `pnpm supabase:start`
2. `pnpm supabase:functions:serve`
3. `pnpm dev`

### Database & Types

- `pnpm supabase:types` - Generate TypeScript types from Supabase schema
- `pnpm seed:committee` - Seed committee members from CSV
- `pnpm seed:waitlist` - Seed waitlist with fake data
- `pnpm seed:members` - Seed members with fake data

### Testing & Quality

- `pnpm test` - Run all tests (unit + e2e)
- `pnpm test:unit` - Run Vitest unit tests
- `pnpm test:e2e` - Run Playwright end-to-end tests
- `pnpm lint` - Run ESLint and Prettier checks
- `pnpm format` - Format code with Prettier
- `pnpm check` - Run Svelte type checking

### Build & Deploy

- `pnpm build` - Build for production
- `pnpm preview` - Preview production build

## Architecture

### Tech Stack

- **Frontend**: SvelteKit 2.x with Svelte 5 syntax, TypeScript, Tailwind CSS
- **Backend**: Supabase (PostgreSQL + Auth + Edge Functions)
- **Database ORM**: Kysely for mutations, Supabase client for queries
- **State Management**: TanStack Query (@tanstack/svelte-query) for server state
- **Payments**: Stripe integration with webhooks
- **Deployment**: Cloudflare (adapter-cloudflare)
- **Monitoring**: Sentry for error tracking
- **Package Manager**: pnpm

### Key Patterns

### Test Driven Development

- All code MUST be covered by tests, we are NOT aiming for 100% test coverage, but key functionality needs to be tested
- ALWAYS write tests first, verify they fail
- AFTER writing tests, write code to pass the tests

#### E2E Testing Guidelines

- **Reference working tests**: When fixing failing tests, ALWAYS compare with similar working tests to understand
  correct patterns
- **Use unique test data**: Generate unique emails/IDs using timestamps and random suffixes to avoid conflicts:
  ```javascript
  const timestamp = Date.now();
  const randomSuffix = Math.random().toString(36).substring(2, 15);
  email: `admin-${timestamp}-${randomSuffix}@test.com`
  ```
- **Authentication helpers**: Always use `makeAuthenticatedRequest()` instead of direct authorization headers
- **Service dependencies**: E2E tests require all services running (see Environment Setup section)
- **Response format consistency**: API responses follow `{success: true, [resource]: data}` pattern

#### Database Access

- **Queries**: Use Supabase client directly (`supabase.from('table').select()`) ONLY from client side, for queries on the SERVER side, use kysely
- **Mutations**: Use Kysely with RLS (`executeWithRLS()` helper in `src/lib/server/kysely.ts`)
- **Types**: Auto-generated from Supabase schema in `database.types.ts`
- **Svelte patterns**: Prefer loader/actions where possible, use SuperForm. Only resort to /api/ route handlers when it makes sense (i.e we just have a small mutation like a toggle)
- **Svelte types**: SvelteKit has a very comprehensive type generation system (import from './$types'). Prefer that over custom types and DO NOT use any.

#### Authentication & Authorization

- Custom hooks system in `hooks.server.ts` with session management
- Role-based access control (RBAC) using JWT claims
- RLS (Row Level Security) enforced at database level
- Session validation with `safeGetSession()` helper

#### Component Architecture

- Svelte 5 syntax with runes (`$state`, `$derived`, `$props`, `$effect`)
- UI components in `src/lib/components/ui/` (shadcn-svelte style)
- Data fetching with TanStack Query (`createQuery`, `createMutation`)
- Component naming: kebab-case (e.g., `my-component.svelte`)
- TankStack Query Svelte uses a thunk pattern to create queries/mutation `createQuery(() => ({}))`

### Directory Structure

#### Routes

- `(public)/` - Public routes (no auth required)
- `dashboard/` - Protected admin/member routes
- `api/` - Server-side API endpoints
- `auth/` - Authentication flows

#### Key Libraries

- `src/lib/server/` - Server-side utilities (Kysely, Stripe, roles)
- `src/lib/components/ui/` - Reusable UI components
- `src/lib/schemas/` - Validation schemas (Valibot)
- `supabase/functions/` - Edge functions (Deno runtime)
- `supabase/migrations/` - Database migrations

#### Authentication Flow

1. Auth handled via Supabase Auth with Discord OAuth
2. Session management in `hooks.server.ts` with JWT validation
3. Role-based routing with `roleGuard` middleware
4. RLS policies enforce data access at DB level

#### Workshop Management

- Draft workshops can have manual priority attendees added
- Publishing triggers batch invitation system via edge functions
- Stripe Payment Links generated for each attendee
- Email notifications handled by edge functions

##### Workshop State Transitions

- **Draft → Published**: Triggers invitation edge functions
- **Published → Finished**: Requires no pending/invited attendees
- **Any State → Cancelled**: Except finished/already cancelled
- **State validation**: Always check current state before transitions
- **Edge functions**: Publishing integrates with `workshop_inviter` function

### Environment Variables

Required for development:

- `PUBLIC_SUPABASE_URL` - Supabase project URL
- `PUBLIC_SUPABASE_ANON_KEY` - Supabase anonymous key
- `PUBLIC_SITE_URL` - Site URL for redirects
- `STRIPE_SECRET_KEY` - Stripe API key
- `SENTRY_AUTH_TOKEN` - Sentry error tracking (optional)

## Code Style & Conventions

### Component Guidelines

- Use Svelte 5 syntax exclusively
- Minimize client-side components, favor SSR
- Always implement loading and error states for data fetching
- Use semantic HTML elements
- Implement proper error handling and logging
- ALWAYS use svelte-shadcn components first, resort to tailwind 4 custom styles if components do not suffice
- ALWAYS use superform. If the submission is client-only, then use SPA mode.
- ALWAYS use our form components in src/components/ui/form
- ALWAYS use dinero.js for any money operations
- ALWAYS use day.js for any date operations
- ALWAYS try to avoid $effects unless is absolutely necessary. Prefer $derived runes and event handlers

For forms, ALWAYS use the Form component from src/components/ui/form. This is the usage:
```svelte
<form>
 <Form.Field>
  <Form.Control>
   <Form.Label />
   <!-- Any Form input component -->
  </Form.Control>
  <Form.Description />
  <Form.FieldErrors />
 </Form.Field>
</form>
```

### Database Guidelines

- Use Supabase client for queries only
- Use Kysely with `executeWithRLS()` for all mutations
- Always work within RLS constraints
- Generate types after schema changes: `pnpm supabase:types`
- Use the `has_any_role` database utility to check for permissions, example usage:
```sql
SELECT has_any_role(
                    (
                        SELECT auth.uid()
                    ),
                    ARRAY ['committee_coordinator', 'president', 'admin']::role_type []
                )
```
- If a new migration is applied, generate database types with pnpm supabase:types
### API Guidelines

- Validate inputs with Valibot schemas
- Use proper HTTP status codes
- Implement comprehensive error handling
- Log errors to Sentry
- Follow role-based access patterns
### Documentation
When significant changes have been made, always update this document to reflect them so subsequent agents pick the changes.

#### API Endpoint Development

- **Pattern consistency**: New endpoints MUST follow existing endpoint patterns exactly
- **Reference implementation**: Use existing endpoints as templates (e.g., `/api/workshops/[id]/publish/+server.ts`)
- **Security pattern**: All workshop endpoints use roles: `['admin', 'president', 'beginners_coordinator']`
- **Response format**: Always return `{success: true, [resource]: updatedRecord}`
- **Error handling**: Use same Sentry integration and error mapping patterns
- **Business logic**: Implement state validation before mutations (check current state, validate transitions)
- **Database transactions**: Use `executeWithRLS()` wrapper for all mutations

### File Naming

- Components: kebab-case (e.g., `workshop-detail.svelte`)
- API routes: RESTful patterns with `+server.ts`
- Types: PascalCase interfaces
- Utilities: camelCase functions

## Development Workflows

### Local Development Setup Order

1. **Start services in correct order**:
    - `pnpm supabase:start` (must be first)
    - `pnpm supabase:functions:serve` (for edge functions)
    - `pnpm dev` (for development/testing)

2. **Before running E2E tests**: Ensure all three services are running
3. **Database changes**: Always run `pnpm supabase:types` after schema changes
4. **Test failures**: Compare with working tests in same codebase before debugging

### Debugging Guidelines

- **Test failures**: Always check service dependencies first (supabase, edge functions, dev server)
- **Authentication issues**: Verify `makeAuthenticatedRequest` helper usage vs direct headers
- **Response format issues**: Check API returns `{success: true, [resource]: data}` format
- **Test conflicts**: Ensure unique test data generation to prevent interference
- **Missing endpoints**: Use existing endpoint as exact template for implementation
