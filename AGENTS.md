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

### Service Layer (MANDATORY)

ALL database mutations go through services in `src/lib/server/services/`.

```typescript
// In +page.server.ts
const service = createEntityService(platform!, session);
const result = await service.create(validatedData);
```

- Factory functions for instantiation
- `executeWithRLS()` wrapper for all Kysely mutations
- Valibot schemas exported for form validation
- Private `_transactional` methods for cross-service coordination

### Database Access

| Context | Tool | Pattern |
|---------|------|---------|
| Client queries | Supabase client | `supabase.from().select()` |
| Server queries | Kysely + RLS | `executeWithRLS(db, {claims: session}, ...)` |
| Server mutations | Service layer | Via service class methods |

### Remote Functions (`.remote.ts`)

Remote functions MUST delegate to the service layer:

```typescript
// In *.remote.ts file
import { command, getRequestEvent } from '$app/server';
import { authorize } from '$lib/server/auth';
import { createWorkshopService } from '$lib/server/services/workshops';

export const deleteWorkshop = command(
  v.pipe(v.string(), v.uuid()),
  async (workshopId) => {
    const { locals, platform } = getRequestEvent();
    const session = await authorize(locals, WORKSHOP_ROLES);
    const service = createWorkshopService(platform!, session);
    await service.delete(workshopId);  // MUST use service
    return { success: true };
  }
);
```

- **NEVER** use raw Kysely/`executeWithRLS` in remote functions
- **ALWAYS** instantiate service via factory function
- Validation handled by Valibot schema (first arg to `command`/`query`)
- Authorization via `authorize()` or `locals.safeGetSession()`

### Forms

ALWAYS use Superforms + our form components:

```svelte
<Form.Field>
  <Form.Control><Form.Label />{input}</Form.Control>
  <Form.FieldErrors />
</Form.Field>
```

### API Response Format

```typescript
// Success
{ success: true, [resourceName]: data }

// Error  
{ success: false, error: string }
```

## ANTI-PATTERNS (FORBIDDEN)

| Pattern | Why |
|---------|-----|
| `as any`, `@ts-ignore` | Type safety required |
| Direct Kysely in loaders | Must use `executeWithRLS()` |
| Skip service layer | ALL mutations through services |
| Direct Kysely in `.remote.ts` | MUST use service layer |
| Empty catch blocks | Log to Sentry |
| `$effect` when `$derived` works | Prefer derived runes |

## COMMANDS

```bash
# Dev (start in order)
pnpm supabase:start        # 1. Start Supabase
pnpm supabase:functions:serve  # 2. Edge functions
pnpm dev                   # 3. SvelteKit dev

# Database
pnpm supabase:types        # Generate types after schema changes
pnpm supabase:reset        # Reset + seed local DB

# Testing
pnpm test:unit             # Vitest
pnpm test:e2e              # Playwright (requires all 3 services)
pnpm check                 # Svelte type check (NOT raw tsc)
```

## TECH STACK

- **Frontend**: SvelteKit 2.x, Svelte 5 (runes), Tailwind CSS, shadcn-svelte
- **Backend**: Supabase (Postgres + Auth + Edge Functions)
- **ORM**: Kysely (mutations), Supabase client (queries)
- **State**: TanStack Query (`createQuery(() => ({}))` thunk pattern)
- **Payments**: Stripe
- **Validation**: Valibot
- **Forms**: Superforms
- **Deployment**: Cloudflare (adapter-cloudflare + Hyperdrive)
- **Monitoring**: Sentry

## EXPERIMENTAL FEATURES

- **Remote Functions**: `remoteFunctions: true` in svelte.config.js
- **Async Components**: `async: true` compiler option
- Uses `.remote.ts` files for server functions callable from client

## SERVICE DOMAINS

| Domain | Services | Purpose |
|--------|----------|---------|
| `members/` | MemberService, ProfileService, WaitlistService | Membership management |
| `workshops/` | WorkshopService, AttendanceService, RefundService, RegistrationService | Event coordination |
| `inventory/` | ItemService, ContainerService, CategoryService, HistoryService | Equipment tracking |
| `invitations/` | InvitationService | Member onboarding |
| `settings/` | SettingsService | App configuration |

## ROLES (RBAC)

```typescript
WORKSHOP_ROLES: ['workshop_coordinator', 'president', 'admin']
SETTINGS_ROLES: ['president', 'committee_coordinator', 'admin']
INVENTORY_ROLES: ['quartermaster', 'admin', 'president']
```

Check with `authorize(locals, ROLES)` in API routes or `has_any_role()` in SQL.

## NOTES

- Type check with `pnpm check` not `tsc` (Svelte compiler required)
- E2E tests need unique data: `test-${Date.now()}-${randomSuffix}@example.com`
- Use `dinero.js` for money, `day.js` for dates
- TanStack Query uses thunk pattern: `createQuery(() => ({...}))`

---

**See Also**: `src/lib/server/services/AGENTS.md`, `supabase/AGENTS.md`, `e2e/AGENTS.md`
