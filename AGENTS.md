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
- For Playwright-side setup/helpers, prefer importing service classes directly over runtime-aware factories when you need portable test wiring; inject dependencies like Stripe explicitly instead of relying on transitive `$env/dynamic/private` imports.
- Workshop E2E helpers in `e2e/attendee-test-helpers.ts` are now service-backed; do not add new deprecated `/api/workshops/*` transport usage in tests.
- `supabase/functions/stripe-sync` now runs in batch mode: it fetches all `standard_membership_fee` subscriptions via Stripe pagination and syncs only customer IDs where `member_profiles.updated_at` is older than 24h.
- `supabase/functions/stripe-sync` reuses cached Stripe monthly price ID from `settings.stripe_monthly_price_id` when it is <=24h old, and refreshes cache from Stripe when stale/missing.
- Stripe sync cron should call the edge function once daily (UTC midnight) instead of one HTTP request per customer; migration `20260217103000_refactor_stripe_sync_cron_batch.sql` handles unschedule/reschedule.
- Manual Stripe sync E2E is gated by `RUN_STRIPE_SYNC_MANUAL_E2E=true` in `e2e/stripe-sync-manual.spec.ts` and validates sync by seeding data, mutating Stripe state, then invoking `/functions/v1/stripe-sync` directly.
- Members dashboard status filtering supports three states: `active`, `inactive`, `paused`; `paused` means `is_active = true` and `subscription_paused_until` is in the future.
- `member_management_view` now exposes computed `membership_status` (`active`/`inactive`/`paused`) plus `paused_until` aliasing `member_profiles.subscription_paused_until` for member list filtering.
- Tailwind theme tokens consumed through `hsl(var(--token))` must stay as HSL channel values, not raw color keywords or `oklch(...)`; invalid `--popover`/`--sidebar-*` values make `bg-popover` and `bg-sidebar` render transparent in dropdowns, sheets, and similar modal surfaces.
- `supabase/functions/process-emails` validates `dataVariables` as `Record<string, string>`; edge functions that enqueue transactional emails must stringify numeric template variables (for example `workshop_count` in `process-workshop-announcements`).
- `RegistrationService` now supports two actor contexts: `member` (authenticated user) and `system` (public/service-role operations). Use `createRegistrationService(platform, session)` for member flows and `createPublicRegistrationService(platform)` for public registration flows. The actor context is set internally by the factory functions.
- Public registration flows use `buildServiceRoleSession()` from `src/lib/server/services/shared/service-auth.ts` to create a service-role backed session for RLS execution without requiring an authenticated user.
- When instantiating `RegistrationService` directly (e.g., in E2E helpers), pass the actor context as the third constructor parameter: `new RegistrationService(kysely, session, { kind: "member", memberUserId: session.user.id }, stripe, logger)`.
- External registration now uses Stripe Checkout Session methods (`createExternalCheckoutSession`, `completeExternalRegistrationFromCheckoutSession`) rather than PaymentIntents. Amount is always derived server-side from `workshop.price_non_member`; client-provided amounts are never trusted.
- External user identity is normalized by email (lowercase, trimmed). The `upsertExternalUser` helper either creates a new `external_users` row or updates the existing one's profile fields (name, phone) on each registration attempt.
- `completeExternalRegistrationFromCheckoutSession` is idempotent by `checkoutSessionId` (`club_activity_registrations.stripe_checkout_session_id`): re-calling with the same session returns the existing registration.
- Public workshop registration route contract: `+page.server.ts` should return `404` for unavailable workshops (`NOT_FOUND`/`NOT_PUBLISHED`/`NOT_PUBLIC`/missing external price) and redirect full workshops to `/workshops/[id]/full`; checkout completion is handled in `confirmation/+page.server.ts` via `session_id` query param.
- `createExternalCheckoutSession` now creates an embedded Checkout Session (`ui_mode: "embedded"`) and returns `checkoutClientSecret`; `returnUrl` must include `{CHECKOUT_SESSION_ID}` for post-payment completion routing.
- External embedded checkout now explicitly enables required individual name capture via `name_collection.individual` in `RegistrationService.createExternalCheckoutSession(...)` so public registration completion always receives a customer name.
- Embedded external checkout sessions now set `customer_creation: "always"` and `invoice_creation.enabled = true`; completion flow attempts to set `payment_intent.receipt_email` from `checkoutSession.customer_details.email` to ensure receipt delivery.
- Public register route server load (`src/routes/(public)/workshops/[id]/register/+page.server.ts`) now creates the checkout session up front and returns `checkoutClientSecret` with workshop data.
- Public register page (`src/routes/(public)/workshops/[id]/register/+page.svelte`) loads Stripe.js on mount and mounts embedded checkout via `stripe.initEmbeddedCheckout({ clientSecret })` into `#workshop-checkout` (no extra "continue" button).
- Public workshop register page now uses a single responsive card layout with workshop details and embedded checkout side-by-side on desktop and stacked on mobile.
- Public workshop register checkout container now uses a fixed viewport-based height with `overflow-y-auto` to prevent embedded checkout growth from overflowing the surrounding card.
- Confirmation route server load exists at `src/routes/(public)/workshops/[id]/confirmation/+page.server.ts` and finalizes registration by calling `completeExternalRegistrationFromCheckoutSession(...)` using `session_id` from query params.
- Public workshop confirmation page UI (`src/routes/(public)/workshops/[id]/confirmation/+page.svelte`) now wraps success messaging/actions in a card and no longer displays the raw checkout session reference.
- Public workshop confirmation page primary action is now a `Close` button that calls `window.close()` (instead of navigating back home).
- Public workshop registration full-state UX now redirects `src/routes/(public)/workshops/[id]/register/+page.server.ts` to `/workshops/[id]/full` when `getExternalRegistrationGate()` returns `FULL`; the register page assumes an eligible workshop payload and no longer renders an inline unavailable/full branch.
- Workshop admin modal (`src/lib/components/workshops/workshop-event-modal.svelte`) now shows a "Copy public registration link" button under attendee count when a workshop is both `is_public` and `published`, copying `/workshops/[id]/register` to clipboard for sharing.
- Workshop attendee manager (`src/lib/components/workshops/attendee-manager.svelte`) now shows an `External` pill under each attendee status badge when the attendee is an external/public registrant (`external_user_id` present).

---

**See Also**: `src/lib/server/services/AGENTS.md`, `supabase/AGENTS.md`, `e2e/AGENTS.md`
