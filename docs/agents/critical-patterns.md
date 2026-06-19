# Critical Patterns

## Service Layer (MANDATORY)

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

## Database Access

| Context | Tool | Pattern |
|---------|------|---------|
| Client queries | Supabase client | `supabase.from().select()` |
| Server queries | Kysely + RLS | `executeWithRLS(db, {claims: session}, ...)` |
| Server mutations | Service layer | Via service class methods |

## Ecto + Transaction Pooler (PgBouncer)

Production connects to Supabase via a transaction-mode connection pooler (PgBouncer). **This invalidates named prepared statements between transactions.** Ecto must use unnamed prepared statements:

```elixir
# In apps/phoenix/config/runtime.exs (prod block)
config :dhc, Dhc.Repo,
  url: database_url,
  prepare: :unnamed   # REQUIRED for transaction poolers
```

**Symptoms if missing:** `invalid_sql_statement_name` (prepared statement "ecto_X" does not exist) or `protocol_violation` (bind message supplies N parameters, but prepared statement requires M). These errors cascade into Oban crashes, Stripe sync failures, and general API instability.

## Remote Functions (`.remote.ts`)

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

## Forms

ALWAYS use Superforms + our form components:

```svelte
<Form.Field>
  <Form.Control><Form.Label />{input}</Form.Control>
  <Form.FieldErrors />
</Form.Field>
```

## Phoenix Read-Migration API Conventions (ADR 0005)

Conventions established by the Waitlist migration (#105–#107) and reinforced by the Members migration (#122). Apply to all remaining PostgREST read-migration slices (Workshops, Inventory).

- **Spec-first**: write the OpenAPI contract in `apps/phoenix/priv/api/openapi.yaml` before implementation. Generate Phoenix controller stubs via `mix gen.controllers`, then the TypeScript client via `pnpm api-gen`.
- **One domain = one tag = one URL root**: keep all endpoints for a domain under one tag and one URL root. Do not split a domain's reads and commands across different tags/roots (e.g. invitation reads live under `GET /api/invitations` alongside `POST /api/invitations`, not nested under `/api/members/invitations`).
- **Domain endpoints, not table/view proxies**: expose domain concepts, not storage shapes. `GET /api/waitlist/status` (not `settings`), `GET /api/members/insurance-form` (not `settings`), `GET /api/members` (not `member_management_view`).
- **Response envelope**: all endpoints use `{ data: ... }`. Error responses use `{ errors: { detail: string } }`.
- **camelCase DTOs**: all response fields are camelCase. Omit internal/leaky fields (search indexes, internal FKs, timestamps the UI doesn't use) — add fields back when a real consumer appears.
- **Cursor pagination for list endpoints**: opaque Base64 cursor, prev/next only (no random page jumps). Cursor binds to request params (limit, sort, direction, filters, q); mismatched cursors return `400`. `id` as deterministic tiebreaker. Exact `COUNT(*)` for `totalCount` (never `estimated`).
- **Multi-value filters**: comma-separated single param (e.g. `?membershipStatus=active,paused`). Absent or empty = all values (no filter).
- **Websearch**: `websearch_to_tsquery('english', ?)` on the underlying `search_text` column, exposed as `q` query param.
- **RBAC via `RequireAuth` plug**: role lists mirror the existing RLS policies. Self-read (where applicable) is endpoint-specific, not a blanket rule.
- **`auth.users` access**: use a read-only Ecto schema (`Dhc.Auth.AuthUser`) to join email; do not call PostgREST-era helper functions like `get_email_from_auth_users`.
- **Computed view columns reproduced in Ecto**: when a view computes a domain field (e.g. `membership_status` CASE), reproduce the computation in the Phoenix context query rather than depending on the view.

## API Response Format

```typescript
// Success
{ success: true, [resourceName]: data }

// Error
{ success: false, error: string }
```
