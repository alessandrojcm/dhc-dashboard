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

All remote functions that accept input use a Valibot schema. Authenticated handlers obtain the request with `getRequestEvent()` and authorize through `authorize(locals, <capability>)` or `authorizationFor(session).require(<capability>)` from `#lib/server/authorization` (never by intersecting role sets). Phoenix calls forward request cookies through `apiClientOptions(event.cookies)`. Domain mutations belong in Phoenix contexts; remote functions must not access Kysely or `executeWithRLS` directly.

## UI: `#lib/components/ui` Owns Every Interactive Primitive

Compose, don't reinvent: reach for the shared component first and style only what it does not cover. A hand-rolled control diverges from the theme, drops the focus and keyboard behaviour the shared one already implements, and no one updates it when the theme moves.

Substitute the control you are about to type for the component that owns it:

| Instead of | Render |
|------------|--------|
| `<button>` | `Button` (`variant`, `size`) |
| `<input type="text\|email\|tel\|password">` | `Input`, or `PhoneInput` for a phone field |
| `<textarea>` | `Textarea` |
| `<select>` | `Select.*`; `NativeSelect` for the native dropdown (mobile, many options) |
| `<input type="checkbox">` | `Checkbox` |
| `<input type="radio">` | `RadioGroup.*` |
| `<input type="date">`, `type="time"` | `date-picker.svelte`; a date range is `Popover` + `RangeCalendar` |
| `<dialog>`, a modal | `Dialog.*`; `AlertDialog.*` to confirm, `Sheet.*` for a side or bottom panel |
| `<details>` / `<summary>` | `Collapsible.*` or `Accordion.*` |
| a filterable dropdown | `Popover` + `Command` |
| a label + control + error trio | `Field.Field` + `Field.Label` + `Field.Error` (see "Remote Forms") |
| a bare `<label for>` on a custom control | `Label` bound to the trigger's `id` |

The same rule covers hand-built blocks: `Empty` for an empty result, `Skeleton` or `Spinner` for loading, `Separator` for a divider, `Badge` for a pill, `Alert` for a callout, `sonner`'s `toast()` for a notification.

Every other name comes from the registry — add a missing one rather than writing a local variant:

```bash
pnpm dlx shadcn-svelte@latest add <name> -c apps/web -y
```

Two rows are compositions that already exist rather than registry items, so they are not `add` targets: `date-picker.svelte` (this project's `Popover` + `Calendar`) and a combobox (`Popover` + `Command`). `apps/web/components.json` holds the alias map (`ui` → `#lib/components/ui`) and the registry URL; the primitives underneath are `bits-ui` 2.18.1, which feature code imports only through `ui/`. Not yet vendored and worth adding: `empty`, `spinner`, `input-group`. The project is on `@lucide/svelte` 1.x (the registry's major): type an icon component as `LucideIcon`, not `Component<IconProps>` — in 1.x `IconProps` belongs to the base `Icon` component and requires `iconNode`. Icons default to `aria-hidden="true"`; an icon-only control still needs its own `aria-label` or `sr-only` text. Upstream components type refs as `WithElementRef<Attrs, HTMLSelectElement>`; `#lib/utils.ts` accepts that second element argument.

Copy the shape from a page that already does it: `apps/web/src/routes/(public)/waitlist/+page.svelte` (Field + Input + Select + RadioGroup + date picker in one remote form), `apps/web/src/routes/dashboard/members/[memberId]/+page.svelte`, and `apps/web/src/lib/components/ui/pause-subscription-modal.svelte` for a dialog over a date field.

Two boundaries: `apps/web/src/lib/components/ui/**` is vendored registry code and keeps its own native `<select>` internals (the calendar's month and year pickers), and `apps/web/src/routes/prototype/**` plus `routes/dashboard/prototype/**` are throwaway comparison surfaces. Everything a member or operator sees goes through `ui/`.

Before finishing a UI change, walk the diff for interactive elements and confirm each maps to a row above.

Four consequences of that rule that cost real debugging time, all now settled:

- **`type="time"` stays an `Input`.** shadcn-svelte has no time picker; its documented "Time Picker" recipe is `<Input type="time">` inside a `Field.Field`. The substitution table groups it with `type="date"`, but only the date half means `date-picker.svelte` — do not go looking for a time component to add.
- **A segmented single-choice switch is `ToggleGroup type="single"`, not two `Button`s and not `RadioGroup`.** bits-ui renders single-mode items as `role="radio"` with `aria-checked`, so browser tests must query `getByRole("radio", …)`; the old `getByRole("button")` + `aria-pressed` selectors fail against it. Clicking the active item clears a single group, so bind one-way and ignore an empty value in `onValueChange`. A multi-select filter is `ToggleGroup type="multiple"`, whose items stay `role="button"` with `aria-pressed`; an "All" reset is an item in the group (see `routes/dashboard/members/members-table.svelte`).
- **`RadioGroup.Item` cannot render a card via a `child` snippet.** The vendored wrapper types it `WithoutChildrenOrChild` and hard-codes `role="radio"` on its own `<button>`. To make a whole card the radio, put the `RadioGroup.Item` *inside* a `<label>` and select it with `has-[[data-state=checked]]:…` — the item owns the state and keyboard wiring, the label only reads it.
- **`date-picker.svelte` takes `DateValue`, but drafts hold `YYYY-MM-DD` strings.** Bridge with `draftCalendarDate`/`draftIsoDate` in `apps/web/src/lib/training-announcements/announcement.ts`, which go through dayjs (`dayjs(iso)` parses a bare ISO date as *local* midnight). Never route a civil date through `new Date(iso)`, which reads back as the previous day west of UTC, and never use `fromDate`, which returns a `ZonedDateTime` rather than a `CalendarDate`. `draftIsoDate` narrows with `instanceof CalendarDate` so a time value can never stringify into a field the API's `format: date` rejects.

Browser tests drive a date field by opening the popover and clicking the day whose accessible name is its full date (`"Thursday, October 15, 2026"`). Do not target `role="dialog"` — the surrounding `Sheet` is a dialog too, and bits-ui renders each day twice (a `gridcell` plus a `[data-bits-day]` button) carrying the same `data-value`.

## Remote Forms

Spread the remote form or its preflight-enhanced variant onto the native form element, and use the generated field APIs so names, restored values, and `aria-invalid` remain connected:

```svelte
<form {...updateProfile.preflight(memberProfileSchema)}>
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
- **One schema per form** (ALE-353/354/355), in `lib/schemas/`, never in a `.remote.ts` or `server/` module. Pass the same object to `form(schema, …)` / `command(schema, …)` and `.preflight(schema)`. `form()` only constrains the schema *input* (form strings/numbers/booleans/files); its output may be transformed, so the schema ends with one renaming `v.transform` whose result `satisfies` the generated request body and the handler sends `data` unchanged. Do not add a `*ClientSchema` / `*RemoteSchema` twin, re-parse in the handler, or map issue paths with a switch — SvelteKit attaches schema issues to fields. Dates stay `YYYY-MM-DD` strings end to end (date pickers bind `CalendarDate` via `parseDate` / `.toString()`); age rules run on the string. Build schemas from the field validators in `lib/schemas/fields.ts`; forms import their form schema, not the validators.
- Valibot's `partialCheck` still runs when one of its fields already failed. A cross-field rule (guardian details for minors) uses `v.rawCheck` that re-checks its inputs and `addIssue({ path: [{ type: "object", origin: "value", input, key, value }] })` so the issue lands on `issue.<key>`.
- A read-only value shown inside a remote form (the login email on the profile page) is a plain `<Input readonly value=…>` with no `name` and no `field.as(...)`, and stays out of the schema.
- A remote `command` that submits a client-built list validates each entry with the per-entry schema in the UI, stores the output, and the command takes `v.array(entry)`. The entry schema must be idempotent (its output re-parses to itself); keep a test for that.
- Every control a remote form submits must take its name from the field (`{...form.fields.x.as(type)}` or `name={form.fields.x.as(type).name}`); SvelteKit 3 encodes names as `<field>/<form id>` and rejects the whole submission (`form_field_unbound`) if any key is a plain `name="x"`. bits-ui `Select.Root` / `RadioGroup.Root` / `Switch` render their own hidden input under a `name` prop, so leave them unnamed and submit the value with `<input {...form.fields.x.as("hidden", value)} />` (render it only when set for optional enums). Tests that read a form's `FormData` must strip the `/<form id>` suffix.
- `submit()` awaits the post-submission `refreshAll()` before resolving, so a refresh that re-renders the route (e.g. Invitation Acceptance after a terminal payment failure) unmounts the component — and its `useMachine` actor — before the `enhance` callback continues. Do user-visible work that must survive that (toasts) directly in the callback.
- Treat `invalid(...)`, `redirect(...)`, and `error(...)` as control-flow exceptions. Keep them outside broad catches or explicitly rethrow them.
- Use `.pending` for submission state and `.result` only for ephemeral post-submission feedback.

## Real PostgreSQL Concurrency Tests

- `Ecto.Adapters.SQL.Sandbox.unboxed_run/2` commits outside the normal test-owner transaction. Cleanup must remove both domain rows and committed side effects, including attempt-scoped Oban jobs; do not rely on sandbox rollback.
- `Sandbox.allow(Repo, self(), self())` inside a `Task` does **not** produce a race: the sibling shares the one sandbox connection, so the operations serialize and the test proves nothing about concurrency. Build the fixture, run the competing operations, and clean up inside `unboxed_run` (see `apps/phoenix/test/dhc/inventory/availability_commands_test.exs` for the fixture/`race`/cleanup helpers).
- **Never nest `unboxed_run`.** Its first step is `checkin/1`, so an inner call hands the *outer* connection back to the pool and the rest of the outer body runs connection-less — surfacing as pool-checkout timeouts, not as an ownership error. Create every committed fixture row in the one outer `unboxed_run`.
- To wait for *another backend* to block on a row lock (proving a command re-reads under the lock), poll `pg_stat_activity` from inside one SQL `DO` block with `pg_sleep` and `pg_stat_clear_snapshot()` per iteration — activity stats are snapshotted per transaction, so a loop without the clear never sees the waiter — rather than sleeping in the test process.

## Domain Conflicts Instead of Server Errors

- A command whose interlock is also backed by a database constraint must translate that constraint, not let it raise. Take the row lock that serializes the command, and additionally attach `Ecto.Changeset.unique_constraint/3` with the index name and return the domain reason (`Repo.insert` + `case`, not `Repo.insert!`). The lock handles command-against-command; the translated constraint handles anything writing outside the seam, so a race never surfaces as a `Postgrex.Error`.
- **Lock order is part of the contract, not just lock presence.** Commands that depend on a container lock that container chain `FOR SHARE` **before** the item `FOR UPDATE` (root first): a move locks the destination chain first; a restore locks the item's current chain first. That matches container archive, which locks the container (and its subtree) before any item row. Reversing either pair deadlocks. After the item lock come the dependent rows (the loan, the open maintenance period, the item's live loans). A command that locked the loan first — e.g. a member cancelling by loan id — deadlocks against one holding the item and wanting the loan. Since GH-508 (ADR 0023) this order is encoded **once**, in `Dhc.Inventory.AvailabilityCommands.with_locked_item/2`: a command reached by a loan id resolves the loan's `item_id` unlocked purely to learn *which* item to lock, takes the item lock, then re-reads the loan `FOR UPDATE` under it, so nothing is decided from the unlocked read. A restore peeks the item only to learn which chain to share-lock; if the locked row sits in a different container, the transaction rolls back and retries from a fresh peek rather than locking a new chain while holding the item. Add a new transition as a `run/4` clause under that primitive; do not open a new `Repo.transaction` with its own locking in `OperatorLoans`, `MemberLoans`, or `OperatorItemLifecycle` — those are facades.
- **Constraint translation is centralized in `AvailabilityCommands.persist/1`.** It declares the partial unique indexes and the principal foreign keys on every changeset and maps them to domain reasons, and never uses a bang write. A race or an out-of-seam writer is `{:error, :already_allocated | :duplicate_request | :maintenance_open | :unknown_actor}`, never a `Postgrex.Error`.
- **Advisory reads reuse the command's predicates.** The queue's `ready_for_checkout?` and the checkout gate both call `Dhc.Inventory.LoanPolicy`; an advisory value may be stale but must never be computed by a different rule.
- **Comparing a stored UTC timestamp against a loan date goes through `ClubCalendar.on_date/1`, not `DateTime.to_date/1`.** A handover at 23:30 UTC is already the next day in Dublin summer time, so `to_date/1` compares the wrong calendar day. `today/0`, `on_date/1`, and `to_utc/2` convert with the `tz` time-zone database owned by `Dhc.ClubCalendar`.
- Guards that run raw SQL must not pattern-match a single expected row shape (`%{rows: [[value]]}`); a recursive CTE over a missing row returns no rows and raises `MatchError` instead of the intended domain error. Match the result and map "missing" onto the same domain reason as "inactive".

## HTTP Errors: Controllers Return `{:error, reason}` (ALE-343)

Controllers return `{:error, reason}`; the domain HTTP module owns status and detail.

- Every Phoenix controller outside the excluded slices (Invitation Acceptance safe views, the non-enumerating magic-link 200, Stripe webhooks) declares `action_fallback DhcWeb.<Domain>HTTP` and returns the domain result: `{:error, reason}`, `{:error, reason, fields}`, `{:error, %Ecto.Changeset{}}` or `{:error, [message]}`. Do not call `put_status`, `json(%{errors: ...})` or `Ecto.Changeset.traverse_errors` for an error in a controller.
- `DhcWeb.Problem` renders the one body `{errors: {detail, code?, fields?}}`: `code` is the reason, only on 409/422 domain reasons; `fields` is public camelCase → messages with placeholders filled; a changeset's `detail` is built from its fields. An undeclared reason raises.
- Declare a reason once in the family's module (`use DhcWeb.Problem, reasons: %{reason => {status, detail}}, fields: %{internal => public}`). When one family needs two details for one domain atom, the controller renames it (`:not_found` → `:loan_not_found`) and the renamed reason keeps the public code via `{status, detail, code}`.
- Shared reasons every family inherits: `:unauthorized`, `:forbidden`, `:not_found` (generic "Not found" — rename it to name a resource) and `:bad_cursor`. A cursor-paginated list read ends its `case` with `error -> DhcWeb.Problem.list_error(error)` (keeps `:bad_cursor`, folds the rest into the family's `:invalid_query`).
- Plugs render the shared reasons with `DhcWeb.Problem.send_reason/2` (it halts); a fixed message outside a reason table uses `Problem.send_detail/4`, which can never carry a `code`.
- OpenAPI has one `Error` schema; a slice types its codes with `allOf: [Error, {errors.code enum}]` rather than a parallel error object.

## HTTP Hardening Seams

- Per-IP policy (rate limits, mandate IPs) resolves the client through `DhcWeb.Plugs.ClientIp`, never `conn.remote_ip`. SvelteKit calls Phoenix server-side, so `remote_ip` is the Worker's egress address. The trusted `x-dhc-client-ip` header counts only with a matching `x-dhc-forwarding-secret`, which `apps/web/src/lib/server/api-client.ts` adds. After that comes Fly's `fly-client-ip`; `x-forwarded-for` is never trusted. `TRUSTED_FORWARDING_SECRET` must be identical in Phoenix (fnox/1Password) and the web Worker (`wrangler secret`).
- The `:api` pipeline rejects non-JSON bodies on unsafe methods with 415 (`DhcWeb.Plugs.RequireJsonBody`). This is CSRF hardening for the `.dublinhemaclub.com` `SameSite=Lax` cookie. `DhcWeb.ConnCase` sends params maps as `application/json`, so a test that posts a raw body sets `content-type` itself.
- `DhcWeb.CacheBodyReader` keeps `raw_body` only for `/api/webhooks/stripe`.
- Email variables that carry a credential (a login link) go through `Dhc.Email.Worker.seal_data_variables/1`, never plain `data_variables`. Job args persist in `oban_jobs` and reach Sentry, and the worker reports variable keys only.
- Web Push endpoints must pass the push-service allowlist in `Dhc.Notifications.WebPush.Endpoint`. It is checked at subscribe time and again before every send (SSRF). Don't loosen it into a hostname heuristic.
- Public intake endpoints must not distinguish "already exists". `POST /api/waitlist/entries` returns the same 202 `{received: true}` for a duplicate email.
- Expired `principal_tokens` and old `auth_rate_limit_windows` rows are pruned daily by `Dhc.Auth.Workers.TokenRetentionWorker` (`Dhc.Auth.Retention`). Add new append-only auth tables to that pass.

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
- **One domain = one tag = one URL root**: keep all endpoints for a domain under one tag and one URL root. Do not split a domain's reads and commands across different tags/roots (e.g. invitation reads live under `GET /api/invitations` alongside `POST /api/invitations`, not nested under `/api/members/invitations`). A domain that outgrows one controller does **not** need extra tags: the `operationId` prefix (the *slice*) names the controller, so one tag can be served by several — see ADR 0003 and `docs/agents/notes.md`.
- **`operationId` is `<slice>.<action>`**: the prefix must underscore to the controller filename that serves the operation (`inventoryItems.list` → `inventory_items_controller.ex`). `mix gen.controllers` derives its files from this, so a mismatched prefix makes it emit an unwanted stub.
- **Domain endpoints, not table/view proxies**: expose domain concepts, not storage shapes. `GET /api/waitlist/status` (not `settings`), `GET /api/members/insurance-form` (not `settings`), `GET /api/members` (not `member_management_view`).
- **Response envelope**: all endpoints use `{ data: ... }`. Error responses use `{ errors: { detail: string } }`.
- **camelCase DTOs**: all response fields are camelCase. Omit internal/leaky fields (search indexes, internal FKs, timestamps the UI doesn't use) — add fields back when a real consumer appears.
- **Cursor pagination for list endpoints**: use `Dhc.CursorPagination` for cursor parse/encode, query direction, `id` tie-break comparisons, ordering, row slicing, and next/previous metadata. Keep domain option parsing, filters, query shape, and sort specs in the domain module. Inventory Item lists are the one exception: the operator list (`OperatorItemList`) and the member catalog (`MemberCatalog`) share their common parameters, category/property filters, slug sort, cursor binding, and exact count through `Dhc.Inventory.ItemQuery` (ALE-347); each supplies only an `%ItemQuery.ReadModel{}` (its extra parameter, scope, search, and projection). Add a shared Item-list parameter or filter there, not in either read model. Opaque Base64 cursors bind to request params (limit, sort, direction, filters, q); mismatched cursors return `400`. Exact `COUNT(*)` for `totalCount` (never `estimated`).
- **Multi-value filters**: comma-separated single param (e.g. `?membershipStatus=active,paused`). Absent or empty = all values (no filter).
- **Websearch**: `websearch_to_tsquery('english', ?)` on the underlying `search_text` column, exposed as `q` query param.
- **RBAC via `RequireSession` plug**: a pipeline requires one capability (`plug RequireSession, capability: :"x.y"`); `Dhc.Auth.Capabilities` alone maps roles to capabilities (ALE-344). Controllers read `current_session.principal`; owner-scoped access (self-read) is checked in the controller with `Capabilities.authorize/3` and conceals with 404, not a blanket rule.
- **Principal access**: join `Dhc.Auth.Principal` through application `principal_id` fields. Supabase `auth.users` is migration/rollback input only and must not be an application query dependency.
- **Computed view columns reproduced in Ecto**: when a view computes a domain field (e.g. `membership_status` CASE), reproduce the computation in the Phoenix context query rather than depending on the view.

## TanStack Query with the Phoenix API

- In Svelte components, spread the generated Hey API `*Options()` or `*InfiniteOptions()` result into `createQuery`/`createInfiniteQuery`; do not hand-write a `queryFn` around the generated SDK function.
- Spread generated `*Mutation()` options into `createMutation` whenever the mutation calls the generated Phoenix client directly. Custom SvelteKit remote functions and non-Phoenix operations may keep a manual `mutationFn`.
- Use generated `*QueryKey()` helpers for invalidation and direct cache updates. Add `select` only for UI-specific response shaping; remember that `queryClient` reads and writes the unselected API response stored in the cache. Generated keys match by prefix, so `fooListQueryKey()` with no arguments invalidates every filtered/paged/infinite page.
- **Test seam exception:** a controller module may accept injected request functions for tests and override the generated `queryFn`/`mutationFn` **only when one is injected** (`...(requests.approve && { mutationFn: requests.approve })`); its default path still spreads the generated options. This is how `loan-queue-board.svelte.ts`, `waitlist-table.svelte.ts` and `member-loans.svelte.ts` stay testable without `vi.mock` (banned).
- Read Phoenix errors through `apiProblem(cause)` from `#lib/api-error.js` (`{ detail?, code?, fields: { field, messages }[] }`, both the plain body and ky's `{ data }`), not `error.errors as {…}` casts or a per-feature parser. `fields` keys are Phoenix's public camelCase names; dotted keys (`values.<definitionId>`, `items.<id>`) stay whole. `code` exists only on 409/422 domain reasons.
- Inventory quartermaster remote forms run their Phoenix call through `inventoryCommand` (`#lib/server/api/inventory-command.js`) with `inventoryManageOptions()`: list the form fields Phoenix may name and pass `propertyLabels` when the form submits `values`. Field-attributable rejections become `invalid(issue.<field>)`; the rest stay `{ ok: false, error }`. Don't call `apiErrorMessage` in those remotes.
- Member Loan request/cancel go through `#lib/inventory/member-loans.svelte.js`; it owns which query families a transition stales (`staleMemberLoanTransition`), the code → member-message map, and the availability/status labels. Whether a loan can be cancelled is Phoenix's `cancellable` (`LoanPolicy.member_cancellable?/1`, shared with the cancel command); don't derive it from `status`.
- URL-backed cursor tables (Waitlist, members, invitations) use `createCursorTableUrl` (`#lib/cursor-table-url.svelte.js`): it owns key prefixing, sort/page-size fallback, the TanStack sorting/pagination adapter, and history (replace for search/filters/sort/page size, push for cursor paging). Search is a debounced draft; a pending draft is written together with any other replace, so a reset is just `setSearch("")` then `setFilter(key, null)`.

## Validating Against Evolving Schema Rows (Inventory typed properties)

When a write validates against rows another command may evolve, share-lock **every** row the validation depends on, not just the obvious parent. The evolution commands in `Dhc.Inventory.Structure` lock `FOR UPDATE` (`update_definition/2`, `retire_definition/1`, `retire_option/1`) and gate themselves on *committed* active values, so they cannot see an in-flight uncommitted insert. A value write that reads any of those rows unlocked can therefore validate against a row that retires before it commits.

`Dhc.Inventory.ItemValues.load_definitions/1` is the reference shape: it loads a category's property definitions **and their options** with `lock: "FOR SHARE"` inside the caller's transaction. Locking only the definitions was a real bug — a concurrent `retire_option/1` slipped between validation and the value insert, leaving an active item pointing at a retired option. Regression coverage: the concurrency test in `test/dhc/inventory/operator_items_test.exs`.

Applies to any future slice that validates item data against definitions/options; extend the lock set when you add a new dependency to a validation path.

**One rule for stored values (ALE-345).** `ItemValues.validate/2` judges *supplied* values; `ItemValues.invalid_stored/2` is the one rule for values *already stored* — the same per-definition checks (required, live option of the definition, retired definition) applied to rows in the database. Both the make-required gate (`Structure.update_definition/2`, judging the proposed definition against every active item) and item restore (`AvailabilityCommands`) call it; do not re-derive "would these stored values still be valid?" with a bespoke query. It reads only values of the definitions passed in, so a value on any other definition is ignored.

**`lock:` is a query option, never a Repo option.** `Repo.get(Schema, id, lock: "FOR UPDATE")` (likewise `get_by/one/all(..., lock:)`) compiles, runs, and silently takes **no lock** — `Ecto.Repo` ignores the unknown option. Seven inventory paths shipped that way and were only caught by reading the logged SQL. Lock a single row with `Dhc.Inventory.Locks.get_for_update/2` (a `from(... lock: "FOR UPDATE")` + `Repo.one/1`) or put `lock:` inside the `from`. `test/dhc/inventory/locks_test.exs` walks the `lib` AST and fails the build if a Repo-option `lock:` reappears.

## Stripe List Requests Must Expand Nested Objects

Stripe list endpoints return nested objects as **bare ID strings** unless the request passes an `expand[]` param. Reading fields off an unexpanded value silently returns nothing and triggers whatever fallback exists downstream — e.g. the stripe-sync job stored every member's `last_payment_date` as their subscription's original `start_date` for months because `latest_invoice.status_transitions.paid_at` was never present (`expand[]=data.latest_invoice` was missing from `/v1/subscriptions`). Regression coverage: `test/dhc/stripe_sync/last_payment_sync_test.exs` (deterministic Req.Test gate) and `test/dhc/stripe_sync/workers/worker_integration_test.exs` (real-sandbox contract test using `backdate_start_date` so `start_date ≠ paid_at`; needs its `@moduletag timeout: 600_000` — one list page against api.stripe.com can take tens of seconds).

When adding any Stripe list call, enumerate the nested fields you consume and pass the matching `expand[]` paths (existing examples: `invitations/stripe_payment.ex`, `membership/reactivation.ex`, `stripe_sync.ex`).

## API Response Format

```typescript
// Success
{ success: true, [resourceName]: data }

// Error
{ success: false, error: string }
```
