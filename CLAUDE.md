# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a SvelteKit application for managing a Historical European Martial Arts club (Dublin Hema Club, DHC for short) dashboard. It handles member management,
workshop coordination, payment processing, and subscription management using Supabase as the backend and Stripe for
payments.

## Development Commands

### Environment Setup

- `pnpm supabase:start` - Start local Supabase development instance
- `pnpm dev` - Start development server (uses Vite with --host flag)
- `pnpm supabase:reset` - Reset and seed the local database

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

#### Database Access

- **Queries**: Use Supabase client directly (`supabase.from('table').select()`)
- **Mutations**: Use Kysely with RLS (`executeWithRLS()` helper in `src/lib/server/kysely.ts`)
- **Types**: Auto-generated from Supabase schema in `database.types.ts`

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

### Database Guidelines

- Use Supabase client for queries only
- Use Kysely with `executeWithRLS()` for all mutations
- Always work within RLS constraints
- Generate types after schema changes: `pnpm supabase:types`

### API Guidelines

- Validate inputs with Valibot schemas
- Use proper HTTP status codes
- Implement comprehensive error handling
- Log errors to Sentry
- Follow role-based access patterns

### File Naming

- Components: kebab-case (e.g., `workshop-detail.svelte`)
- API routes: RESTful patterns with `+server.ts`
- Types: PascalCase interfaces
- Utilities: camelCase functions
