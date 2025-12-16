# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a SvelteKit application for managing a Historical European Martial Arts club (Dublin Hema Club, DHC for short) dashboard. It handles member management, workshop coordination, payment processing, and subscription management using Supabase as the backend and Stripe for payments.

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

#### Test Driven Development

- All code MUST be covered by tests, we are NOT aiming for 100% test coverage, but key functionality needs to be tested
- ALWAYS write tests first, verify they fail
- AFTER writing tests, write code to pass the tests

#### E2E Testing Guidelines

- **Reference working tests**: When fixing failing tests, ALWAYS compare with similar working tests to understand correct patterns
- **Use unique test data**: Generate unique emails/IDs using timestamps and random suffixes to avoid conflicts:
  ```javascript
  const timestamp = Date.now();
  const randomSuffix = Math.random().toString(36).substring(2, 15);
  email: `admin-${timestamp}-${randomSuffix}@test.com`;
  ```
- **Authentication helpers**: Always use `makeAuthenticatedRequest()` instead of direct authorization headers
- **Service dependencies**: E2E tests require all services running (see Environment Setup section)
- **Response format consistency**: API responses follow `{success: true, [resource]: data}` pattern

#### Database Access

- **Queries**: Use Supabase client directly (`supabase.from('table').select()`) ONLY from client side, for queries on the SERVER side, use kysely
- **Mutations**: Use Kysely with RLS (`executeWithRLS()` helper in `src/lib/server/kysely.ts`)
- **Types**: Auto-generated from Supabase schema in `database.types.ts`
- **Svelte patterns**: Prefer loader/actions where possible, USE SUPERFORM ALWAYS. Only resort to /api/ route handlers when it makes sense (i.e we just have a small mutation like a toggle)
- **Svelte types**: SvelteKit has a very comprehensive type generation system (import from './$types'). Prefer that over custom types and DO NOT use any.
- **CRITICAL RLS Pattern**: ALL server-side loaders MUST use `executeWithRLS()` when querying with Kysely. Never use raw Kysely queries in loaders.
- **PROPERTLY TYPE EVERTYHING**: DO NOT use `any` or `unknown` types. ALWAYS use the correct type for the resource being queried.

##### Server-Side Data Loading Pattern

When loading data in `+page.server.ts` files:

```typescript
import { getKyselyClient } from '$lib/server/kysely';
import { executeWithRLS } from '$lib/server/kysely';

export const load = async ({ platform, locals }) => {
	const db = getKyselyClient(platform.env!.HYPERDRIVE!);
	const { session } = await locals.safeGetSession();

	if (!session) {
		throw new Error('No session found');
	}

	const data = await executeWithRLS(db, { claims: session }, async (trx) => {
		return trx.selectFrom('table').selectAll().execute();
	});

	return { data };
};
```

##### Client-Side Data Loading Pattern (For Tables with Filtering/Pagination)

For complex tables with filtering, sorting, and pagination, prefer client-side data loading using TanStack Query. Reference: `src/routes/dashboard/inventory/members/members-table.svelte`

**Loader provides only filter options**:

```typescript
export const load = async ({ platform, locals }) => {
	// Only load data needed for filters/dropdowns
	const categories = await executeWithRLS(db, { claims: session }, async (trx) => {
		return trx.selectFrom('equipment_categories').selectAll().execute();
	});

	return { categories };
};
```

**Component uses TanStack Query for data**:

```svelte
<script lang="ts">
	import { createQuery } from '@tanstack/svelte-query';
	import { page } from '$app/stores';

	let { supabase, categories } = $props();

	// Parse URL params for filters
	const currentPage = $derived(Number($page.url.searchParams.get('page')) || 1);
	const searchTerm = $derived($page.url.searchParams.get('search') || '');

	// Use createQuery with thunk pattern
	const itemsQuery = createQuery(() => ({
		queryKey: ['items', currentPage, searchTerm],
		queryFn: async () => {
			let query = supabase.from('equipment_items').select('*', { count: 'exact' });

			if (searchTerm) {
				query = query.ilike('name', `%${searchTerm}%`);
			}

			const { data, error, count } = await query.range(
				(currentPage - 1) * PAGE_SIZE,
				currentPage * PAGE_SIZE - 1
			);

			if (error) throw error;
			return { items: data, total: count || 0 };
		},
		placeholderData: (prev) => prev // Keep previous data while loading
	}));
</script>

{#if $itemsQuery.isPending}
	<p>Loading...</p>
{:else if $itemsQuery.isError}
	<p>Error: {$itemsQuery.error.message}</p>
{:else}
	<!-- Render table with $itemsQuery.data.items -->
{/if}
```

**When to use each pattern**:

- **Server-side loading**: Simple pages, detail views, forms (most cases)
- **Client-side with TanStack Query**: Tables with complex filtering, pagination, or frequent updates

#### Service Layer Pattern

This project uses a domain-driven service layer pattern for organizing database operations. **ALL new data access code should use this pattern.**

**Location**: `src/lib/server/services/`

**Core Principles**:

1. **No Global Objects**: Services use dependency injection, never global singletons
2. **Factory Functions**: Each domain provides factory functions for easy service instantiation
3. **Validation at Form Layer**: Services accept already-validated data; validation schemas are exported for reuse
4. **Transaction Support**: Services provide both standalone and transactional methods
5. **Standard Error Handling**: Use JavaScript `Error` objects with `cause` property for context
6. **Optional Logger**: All services accept optional logger (defaults to console, production uses sentryLogger)

##### Service Structure Template

```typescript
import * as v from 'valibot';
import { sentryLogger } from '$lib/server/services/shared';
import type {
	Kysely,
	Session,
	Transaction,
	Logger,
	KyselyDatabase
} from '$lib/server/services/shared';
import { executeWithRLS } from '$lib/server/services/shared';

// ============================================================================
// Validation Schemas (exported for reuse in forms/APIs)
// ============================================================================

export const EntityCreateSchema = v.object({
	name: v.pipe(v.string(), v.minLength(1, 'Name is required')),
	description: v.optional(v.string())
});

export const EntityUpdateSchema = v.partial(EntityCreateSchema);

export type EntityCreateInput = v.InferOutput<typeof EntityCreateSchema>;
export type EntityUpdateInput = v.InferOutput<typeof EntityUpdateSchema>;

// ============================================================================
// Service Class
// ============================================================================

export class EntityService {
	private logger: Logger;

	constructor(
		private kysely: Kysely<KyselyDatabase>,
		private session: Session,
		logger?: Logger
	) {
		this.logger = logger ?? console;
	}

	// Public method (creates own transaction)
	async create(input: EntityCreateInput): Promise<Entity> {
		this.logger.info('Creating entity', { name: input.name });

		try {
			return await executeWithRLS(this.kysely, { claims: this.session }, async (trx) => {
				return this._create(trx, input);
			});
		} catch (error) {
			this.logger.error('Failed to create entity', { error, input });
			throw new Error('Failed to create entity', { cause: error });
		}
	}

	async findById(id: string): Promise<Entity> {
		const entity = await this.kysely
			.selectFrom('entities')
			.selectAll()
			.where('id', '=', id)
			.executeTakeFirst();

		if (!entity) {
			throw new Error('Entity not found', { cause: { entityId: id } });
		}

		return entity;
	}

	async update(id: string, input: EntityUpdateInput): Promise<Entity> {
		this.logger.info('Updating entity', { entityId: id });

		return executeWithRLS(this.kysely, { claims: this.session }, async (trx) => {
			return this._update(trx, id, input);
		});
	}

	// Private transactional methods (for cross-service coordination)
	async _create(trx: Transaction<KyselyDatabase>, input: EntityCreateInput): Promise<Entity> {
		return trx.insertInto('entities').values(input).returningAll().executeTakeFirstOrThrow();
	}

	async _update(
		trx: Transaction<KyselyDatabase>,
		id: string,
		input: EntityUpdateInput
	): Promise<Entity> {
		return trx
			.updateTable('entities')
			.set(input)
			.where('id', '=', id)
			.returningAll()
			.executeTakeFirstOrThrow();
	}
}

// ============================================================================
// Factory Function
// ============================================================================

export function createEntityService(
	platform: App.Platform,
	session: Session,
	logger?: Logger
): EntityService {
	return new EntityService(
		getKyselyClient(platform.env.HYPERDRIVE),
		session,
		logger ?? sentryLogger
	);
}
```

##### Usage in page.server.ts

```typescript
import { createEntityService, EntityCreateSchema } from '$lib/server/services/domain';

export const load = async ({ locals, platform }) => {
	const { session } = await locals.safeGetSession();
	const entityService = createEntityService(platform!, session);

	const entities = await entityService.findMany();

	return { entities };
};

export const actions = {
	create: async ({ request, platform, locals }) => {
		const { session } = await locals.safeGetSession();
		const form = await superValidate(request, valibot(EntityCreateSchema));

		if (!form.valid) return fail(400, { form });

		const entityService = createEntityService(platform!, session);
		const entity = await entityService.create(form.data);

		return message(form, 'Entity created successfully!');
	}
};
```

##### Available Service Domains

The following service domains are available for use and extension:

- **`members/`** - Member and profile management
  - `MemberService`: Member CRUD operations, membership queries
  - `ProfileService`: Profile updates with Stripe integration
  - `WaitlistService`: Waitlist CRUD operations, status management

- **`settings/`** - Application settings management
  - `SettingsService`: Settings CRUD operations, toggle functionality

- **`invitations/`** - Invitation system
  - `InvitationService`: Invitation CRUD operations, status updates, validation

- **`workshops/`** - Workshop operations
  - `WorkshopService`: Workshop CRUD operations, publish, cancel, edit permissions
  - `AttendanceService`: Attendance tracking and updates
  - `RefundService`: Refund processing and eligibility checks
  - `RegistrationService`: Registration queries and attendee management

- **`inventory/`** - Inventory management
  - `ItemService`: Item CRUD operations, movement tracking, maintenance status management
  - `ContainerService`: Container CRUD operations, hierarchical management
  - `CategoryService`: Category CRUD operations, attribute schema management
  - `HistoryService`: Item history tracking, movement recording

##### When to Create a New Service vs Extending Existing

**Create a New Service When**:

- The functionality represents a new business domain (e.g., a new `EventService` for general events)
- The service would manage a completely different set of database tables
- The operations don't naturally fit within any existing service's responsibilities

**Extend an Existing Service When**:

- Adding new operations for existing domain entities (e.g., adding `bulkUpdate()` to `MemberService`)
- Adding related queries to the same domain (e.g., adding `getActiveMembers()` to `MemberService`)
- Improving existing service methods (e.g., optimizing query performance)
- Adding validation schemas for new forms in the same domain

**Example: Extending MemberService**

```typescript
// In src/lib/server/services/members/member.service.ts

export class MemberService {
	// ... existing methods ...

	// Adding a new method to existing service
	async getActiveMembers(): Promise<Member[]> {
		return this.kysely
			.selectFrom('user_profiles')
			.innerJoin('member_profiles', 'member_profiles.user_profile_id', 'user_profiles.id')
			.where('member_profiles.status', '=', 'active')
			.selectAll()
			.execute();
	}

	async bulkUpdateStatus(memberIds: string[], status: MemberStatus): Promise<void> {
		this.logger.info('Bulk updating member status', { count: memberIds.length, status });

		await executeWithRLS(this.kysely, { claims: this.session }, async (trx) => {
			await trx
				.updateTable('member_profiles')
				.set({ status })
				.where('id', 'in', memberIds)
				.execute();
		});
	}
}
```

##### Testing Services

All services should have comprehensive unit tests using the provided mock utilities:

```typescript
import { describe, it, expect, beforeEach } from 'vitest';
import { createMockLogger, createMockSession, createMockKysely } from '$lib/server/services/shared';
import { EntityService } from './entity.service';

describe('EntityService', () => {
	let service: EntityService;
	let mockKysely: ReturnType<typeof createMockKysely>;
	let mockSession: ReturnType<typeof createMockSession>;
	let mockLogger: ReturnType<typeof createMockLogger>;

	beforeEach(() => {
		mockKysely = createMockKysely();
		mockSession = createMockSession();
		mockLogger = createMockLogger();
		service = new EntityService(mockKysely, mockSession, mockLogger);
	});

	describe('create', () => {
		it('should create an entity with valid data', async () => {
			const input = { name: 'Test Entity', description: 'Test' };
			const result = await service.create(input);

			expect(mockLogger.info).toHaveBeenCalledWith('Creating entity', { name: input.name });
			expect(result).toBeDefined();
		});
	});
});
```

##### Cross-Service Coordination

When operations span multiple domains, use dependency injection to compose services:

```typescript
export class RegistrationService {
	private logger: Logger;

	constructor(
		private kysely: Kysely<KyselyDatabase>,
		private session: Session,
		logger?: Logger,
		private workshopService?: WorkshopService,
		private memberService?: MemberService
	) {
		this.logger = logger ?? console;
	}

	async registerMemberForWorkshop(memberId: string, workshopId: string): Promise<Registration> {
		// Validate entities exist
		const workshop = await this.workshopService!.findById(workshopId);
		const member = await this.memberService!.findById(memberId);

		// Coordinate across services using a shared transaction
		return executeWithRLS(this.kysely, { claims: this.session }, async (trx) => {
			const registration = await this._create(trx, { memberId, workshopId });

			// You can call other service's _transactional methods here if needed
			// await this.workshopService._updateAttendeeCount(trx, workshopId);

			return registration;
		});
	}
}
```

##### Service Layer Reference Documentation

For complete design documentation and implementation details, see:

- `/instructions/data_layer_service_pattern_design.md` - Complete design document
- `src/lib/server/services/README.md` - Service layer documentation
- `src/lib/server/services/*/` - Individual domain implementations

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
- TanStack Query Svelte uses a thunk pattern to create queries/mutation `createQuery(() => ({}))`

### Directory Structure

#### Routes

- `(public)/` - Public routes (no auth required)
- `dashboard/` - Protected admin/member routes
- `api/` - Server-side API endpoints
- `auth/` - Authentication flows

#### Key Libraries

- `src/lib/server/` - Server-side utilities (Kysely, Stripe, roles)
- `src/lib/server/services/` - **Domain-driven service layer (USE THIS FOR DATA ACCESS)**
- `src/lib/components/ui/` - Reusable UI components
- `src/lib/schemas/` - Validation schemas (Valibot) - services may re-export these
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

- **ALWAYS use the Service Layer**: Never write direct Kysely queries in page.server.ts files
- If no service exists for your domain, create one following the Service Layer Pattern above
- Use Supabase client for client-side queries only
- Use Kysely with `executeWithRLS()` for all mutations (inside services)
- Always work within RLS constraints
- Generate types after schema changes: `pnpm supabase:types`
- Use the `has_any_role` database utility to check for permissions in SQL

```sql
SELECT has_any_role(
    (SELECT auth.uid()),
    ARRAY ['committee_coordinator', 'president', 'admin']::role_type []
)
```

- If a new migration is applied, generate database types with `pnpm supabase:types`

### API Guidelines

- Validate inputs with Valibot schemas (export from services when domain-related)
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
- **Use Services**: API routes should delegate to service layer, not perform direct database operations

### File Naming

- Components: kebab-case (e.g., `workshop-detail.svelte`)
- API routes: RESTful patterns with `+server.ts`
- Types: PascalCase interfaces
- Utilities: camelCase functions
- Services: PascalCase classes with `.service.ts` suffix

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

### Adding New Features Checklist

1. **Determine the domain**: Does this belong to an existing service domain or is it new?
2. **Create/Extend service**: Create new service or extend existing one following the Service Layer Pattern
3. **Write tests first**: Create unit tests for service methods before implementation
4. **Export schemas**: Export Valibot schemas from service for form validation
5. **Implement service methods**: Write service methods with proper error handling and logging
6. **Use in page.server.ts**: Import factory function and schemas, use service in loaders/actions
7. **Update tests**: Ensure all tests pass (`pnpm test:unit`)
8. **Update documentation**: Document any new patterns or significant changes in this file
