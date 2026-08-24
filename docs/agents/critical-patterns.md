# Critical Patterns

## Service Layer (MANDATORY)

Legacy service-layer examples, where still referenced during migration history, live under
`apps/web/src/lib/server/services/`. New domain mutations belong in Phoenix contexts.

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

## Timestamp column names: `created_at`, not `inserted_at`

Production Supabase tables use `created_at`/`updated_at`. Ecto's default `timestamps/1` produces `inserted_at`/`updated_at`. When porting a Supabase table to an Ecto baseline migration, **always** align the baseline with production:

```elixir
# CORRECT — matches production column names
timestamps(type: :timestamptz, inserted_at: :created_at)
```

Then the Ecto schema must declare `field :created_at, :utc_datetime` (not `inserted_at`), and any `Repo.insert_all`/raw writes must set `created_at:`.

This mirrors the `member_profiles`/`user_profiles`/`invitations`/workshop-tables/`settings`/`inventory_*` baseline pattern. All ported baselines now use `created_at`.

**Enforced structurally:** the `elixir-timestamps-missing-created-at` ast-grep rule (in `.ast-grep/rules/`, wired via `sgconfig.yml` + the `mise run ast-lint` task + the opencode.json LSP) fails on any `timestamps/1` call in `apps/phoenix/priv/repo/migrations/` that lacks `inserted_at: :created_at`. Run `mise run ast-test` to validate rule fixtures.

**Source of truth is production, not the baseline.** When a code path (e.g. `stripe_sync/repository.ex`) uses `created_at:` and the testcontainers harness fails because the baseline produced `inserted_at`, the fix is the baseline, not the code.

## SvelteKit Remote Functions and Phoenix Mutations

Choose one client/server boundary for each operation:

- Use SvelteKit `form(...)` for HTML form submissions that benefit from progressive enhancement, schema-backed field state, and field-level validation errors.
- Use generated `@dhc/api-client` TanStack mutation options for imperative Phoenix operations. Reconcile affected data with generated query-key helpers, `invalidateQueries`, or a focused refetch.
- Use `command(...)` only when the browser needs an intentional SvelteKit server facade, such as server-only orchestration that is not already represented by a generated Phoenix operation.
- Do not add a `.remote.ts` wrapper that only duplicates an existing generated Phoenix mutation.
- Use `query(...)` for intentional server-only reads. Phoenix API reads use generated query options as described under "TanStack Query with the Phoenix API".

All remote functions that accept input use a Valibot schema. Authenticated handlers obtain the request with `getRequestEvent()` and authorize through `authorize()` or `locals.safeGetSession()`. Phoenix calls forward request cookies through `apiClientOptions(event.cookies)`. Domain mutations belong in Phoenix contexts; remote functions must not access Kysely or `executeWithRLS` directly.

## Remote Forms

Spread the remote form or its preflight-enhanced variant onto the native form element, and use the generated field APIs so names, restored values, and `aria-invalid` remain connected:

```svelte
<form {...updateProfile.preflight(memberProfileClientSchema)}>
  {@const fieldProps = updateProfile.fields.firstName.as("text")}
  <Field.Label for={fieldProps.name}>First name</Field.Label>
  <Input {...fieldProps} id={fieldProps.name} />
  {#each updateProfile.fields.firstName.issues() as issue (issue.message)}
    <Field.Error>{issue.message}</Field.Error>
  {/each}
</form>
```

- Prefer `form(...)` to `command(...)` when the operation naturally submits a form.
- Use `.preflight(schema)` when client-side validation is appropriate.
- Treat `invalid(...)`, `redirect(...)`, and `error(...)` as control-flow exceptions. Keep them outside broad catches or explicitly rethrow them.
- Use `.pending` for submission state and `.result` only for ephemeral post-submission feedback.

## Real PostgreSQL Concurrency Tests

- `Ecto.Adapters.SQL.Sandbox.unboxed_run/2` commits outside the normal test-owner transaction. Cleanup must remove both domain rows and committed side effects, including attempt-scoped Oban jobs; do not rely on sandbox rollback.

## Discord External Identities

- Resolve Discord login by `(provider, provider_subject)` before looking at profile email.
- Auto-link an unlinked subject only when Discord reports a verified email matching one active Principal.
- Treat Discord email, username, and avatar as metadata only; never overwrite the Principal email or an existing identity link.
- Keep identity creation and session creation in one `Repo.transact/1`, with database uniqueness on both `(provider, provider_subject)` and `(principal_id, provider)`.
- OAuth failures redirect to the generic magic-link fallback and must not disclose whether a Principal exists.

## Discord Server REST

- Call Discord server operations through `Dhc.Discord`; swap the single `Dhc.Discord.Adapter` behaviour in tests rather than calling Nostrum directly.
- Nostrum 0.10.4 is an included application. `Dhc.Discord.RestClientSupervisor` starts its REST ratelimiter only when `DISCORD_BOT_TOKEN` is present; do not start Nostrum's gateway/cache/voice application tree. Keep `:gun` in `:dhc`'s `extra_applications` because Nostrum's REST client does not start Gun itself.
- Development keeps real Discord OAuth identity verification but configures `Dhc.Discord.Adapter.Dev`, which returns safe no-op outcomes for guild reads and mutations. Do not point development onboarding at the live Nostrum adapter.
- Nostrum's stable `Guild.members/2` conversion drops embedded user fields. The production adapter deliberately paginates through the lower-level ratelimited request API and normalizes complete rows into `Dhc.Discord.GuildMember`.
- Discord IDs must be cast to snowflake integers before calling Nostrum's public guild mutation functions. Reject CR/LF in audit reasons before they reach Gun headers.

## Phoenix Read-Migration API Conventions (ADR 0005)

Conventions established by the Waitlist migration (#105–#107) and reinforced by the Members migration (#122). Apply to all remaining PostgREST read-migration slices (Workshops, Inventory).

- **Spec-first**: write the OpenAPI contract in `apps/phoenix/priv/api/openapi.yaml` before implementation. Generate Phoenix controller stubs via `mix gen.controllers`, then the TypeScript client via `pnpm api-gen`.
- **One domain = one tag = one URL root**: keep all endpoints for a domain under one tag and one URL root. Do not split a domain's reads and commands across different tags/roots (e.g. invitation reads live under `GET /api/invitations` alongside `POST /api/invitations`, not nested under `/api/members/invitations`).
- **Domain endpoints, not table/view proxies**: expose domain concepts, not storage shapes. `GET /api/waitlist/status` (not `settings`), `GET /api/members/insurance-form` (not `settings`), `GET /api/members` (not `member_management_view`).
- **Response envelope**: all endpoints use `{ data: ... }`. Error responses use `{ errors: { detail: string } }`.
- **camelCase DTOs**: all response fields are camelCase. Omit internal/leaky fields (search indexes, internal FKs, timestamps the UI doesn't use) — add fields back when a real consumer appears.
- **Cursor pagination for list endpoints**: use `Dhc.CursorPagination` for cursor parse/encode, query direction, `id` tie-break comparisons, ordering, row slicing, and next/previous metadata. Keep domain option parsing, filters, query shape, and sort specs in the domain module. Opaque Base64 cursors bind to request params (limit, sort, direction, filters, q); mismatched cursors return `400`. Exact `COUNT(*)` for `totalCount` (never `estimated`).
- **Multi-value filters**: comma-separated single param (e.g. `?membershipStatus=active,paused`). Absent or empty = all values (no filter).
- **Websearch**: `websearch_to_tsquery('english', ?)` on the underlying `search_text` column, exposed as `q` query param.
- **RBAC via `RequireSession` plug**: role lists mirror the existing RLS policies. Controllers read `current_session.principal`; self-read (where applicable) is endpoint-specific, not a blanket rule.
- **Principal access**: join `Dhc.Auth.Principal` through application `principal_id` fields. Supabase `auth.users` is migration/rollback input only and must not be an application query dependency.
- **Computed view columns reproduced in Ecto**: when a view computes a domain field (e.g. `membership_status` CASE), reproduce the computation in the Phoenix context query rather than depending on the view.

## TanStack Query with the Phoenix API

- In Svelte components, spread the generated Hey API `*Options()` or `*InfiniteOptions()` result into `createQuery`/`createInfiniteQuery`; do not hand-write a `queryFn` around the generated SDK function.
- Spread generated `*Mutation()` options into `createMutation` whenever the mutation calls the generated Phoenix client directly. Custom SvelteKit remote functions and non-Phoenix operations may keep a manual `mutationFn`.
- Use generated `*QueryKey()` helpers for invalidation and direct cache updates. Add `select` only for UI-specific response shaping; remember that `queryClient` reads and writes the unselected API response stored in the cache.

## Stripe List Requests Must Expand Nested Objects

Stripe list endpoints return nested objects as **bare ID strings** unless the request passes an `expand[]` param. Reading fields off an unexpanded value silently returns nothing and triggers whatever fallback exists downstream — e.g. the stripe-sync job stored every member's `last_payment_date` as their subscription's original `start_date` for months because `latest_invoice.status_transitions.paid_at` was never present (`expand[]=data.latest_invoice` was missing from `/v1/subscriptions`). Regression coverage: `test/dhc/stripe_sync/last_payment_sync_test.exs` (deterministic Bypass gate) and `test/dhc/stripe_sync/workers/worker_integration_test.exs` (real-sandbox contract test using `backdate_start_date` so `start_date ≠ paid_at`; needs its `@moduletag timeout: 600_000` — one list page against api.stripe.com can take tens of seconds).

When adding any Stripe list call, enumerate the nested fields you consume and pass the matching `expand[]` paths (existing examples: `invitations/stripe_payment.ex`, `membership/reactivation.ex`, `stripe_sync.ex`).

## API Response Format

```typescript
// Success
{ success: true, [resourceName]: data }

// Error
{ success: false, error: string }
```
