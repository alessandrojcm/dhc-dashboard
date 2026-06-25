# PostgREST Read Migration Inventory

Purpose: track SvelteKit Supabase PostgREST reads (`supabase.from(...).select(...)`) that still need Phoenix read APIs. Excludes Supabase Auth, RPC, Storage, Kysely/service-layer queries, and writes unless a write is colocated with a read-heavy component.

## First migration slice: Beginners workshop / Waitlist

### Agreed API design

- Domain/API name: Waitlist. The current `beginners-workshop` route is UI naming, not the Phoenix API/domain boundary.
- Read endpoints:
  - `GET /api/waitlist/status` → `{ isOpen: boolean }`.
  - `GET /api/waitlist/entries` → paginated admin list with total count.
  - `GET /api/waitlist/analytics` → waitlist analytics summary.
- Admin Waitlist read RBAC: mirror the stricter existing Waitlist SELECT policy: `admin`, `president`, `committee_coordinator`, `beginners_coordinator`, `coach`. Broaden later only if a concrete role need appears.
- Entries response should use a cleaner domain DTO while preserving the same overall data currently used by the UI.
- Entries pagination: cursor-based with total count. The client sees an opaque cursor; Phoenix can encode selected sort value plus `id` internally for deterministic pagination.
- Entries default sort: position ascending.
- Entries search: preserve current full-text websearch behavior, exposed as `q` in the API.
- Entries status filter: default behavior excludes `joined`; explicit status filters use canonical Waitlist Status values.
- Entries sort fields: explicitly whitelisted in the OpenAPI contract.
- Analytics response shape: `{ totalCount, averageAge, genderDistribution, ageDistribution }` where distributions use `{ value }` counts for chart compatibility.

### Existing RLS/RBAC to mirror

- `waitlist` SELECT: authenticated users with any of `admin`, `president`, `committee_coordinator`, `beginners_coordinator`, `coach`.
- `waitlist_management_view`: `security_invoker=true`; depends on underlying table policies.
- `user_profiles` SELECT/ALL policy allows broad committee-style roles: `admin`, `president`, `treasurer`, `committee_coordinator`, `sparring_coordinator`, `workshop_coordinator`, `beginners_coordinator`, `quartermaster`, `pr_manager`, `volunteer_coordinator`, `research_coordinator`; or the active user reading their own active profile.
- `waitlist_guardians` ALL policy allows broad committee-style roles plus `coach`; or the profile owner.
- `settings` SELECT: any authenticated user. Current public waitlist page reads `settings.waitlist_open` server-side with the service role, so public availability is an explicit existing exception to authenticated-only PostgREST access.

- `src/routes/dashboard/beginners-workshop/waitlist-table.svelte` ✅ migrated
  - Resource: `waitlist_management_view`
  - Shape: paginated table with exact count
  - Fields: `id,current_position,full_name,email,phone_number,status,age,initial_registration_date,last_contacted,medical_conditions,admin_notes,social_media_consent,guardian_first_name,guardian_last_name,guardian_phone_number,insurance_form_submitted,last_status_change,search_text`
  - Filters: `status != joined`; optional full-text search on `search_text`
  - Status vocabulary: `waiting`, `invited`, `paid`, `deferred`, `cancelled`, `completed`, `no_reply`, `joined`.
  - UI note: component currently has a stale `declined` badge case; canonical status is the database enum above.
  - Sorting: caller-selected column/direction
  - Pagination: cursor-based previous/next via `cursor` URL param; no random page jumps.
  - Note: same component still updates `waitlist.admin_notes` and invokes invitation functions; those are writes/actions, not read migration targets for this slice.

- `src/routes/dashboard/beginners-workshop/workshop-analytics.svelte` ✅ migrated
  - Resource: `waitlist_management_view`
  - Reads:
    - total waitlist count: `id`, exact count, `status != joined`, head-only
    - average age: `avg_age:age.avg()`, `status != joined`
    - age distribution: `age,value:age.count()`, `status != joined`, ordered by age
  - Resource: `user_profiles`
  - Reads:
    - gender distribution: `gender,count:gender.count()` where `is_active = false`, `waitlist_id IS NOT NULL`, `supabase_user_id IS NULL`

- `src/routes/(public)/waitlist/+page.server.ts` ✅ migrated
  - Resource: `settings`
  - Read: `value` where `key = waitlist_open`
  - Domain meaning: whether the public waitlist accepts new entries.
  - RLS note: `settings` SELECT is authenticated-only, but this route currently uses the service role from a public page.

## Remaining migration inventory

### Members

- Tracking issue: #122 (umbrella). #121 closed as a duplicate. Sliced into tracer-bullet issues (one per endpoint + prefactor + cleanup + raw-string follow-up), mirroring the Waitlist #105–#108 pattern:
  - #123 — Migrate member insurance-form read to Phoenix (`GET /api/members/insurance-form`)
  - #124 — Migrate Members analytics read to Phoenix (`GET /api/members/analytics`)
  - #125 — Migrate Invitations list read to Phoenix (`GET /api/invitations`)
  - #126 — Prefactor: `MemberProfile` + `AuthUser` schemas + `MembershipStatus` enum
  - #127 — Migrate Members list read to Phoenix (`GET /api/members`) — blocked by #126
  - #128 — Replace raw `member_profiles` string access with `MemberProfile` schema — blocked by #126
  - #129 — Clean up migrated Members PostgREST reads — blocked by #123, #124, #125, #127
- Slice boundary: migrate the Members dashboard reads (`member_management_view`, `invitations`, and the insurance form profile config) together; do not bundle Auth/session support from the dashboard layout into this slice.
- Follow-up: once the `MemberProfile` Ecto schema exists (built in #126), replace the remaining raw `"member_profiles"` string-based access with the schema. Tracked as #128. Known call sites: `apps/phoenix/lib/dhc/stripe_sync/repository.ex` (joins + updates), `apps/phoenix/lib/mix/tasks/dhc/seed_members.ex` (`insert_all`).

- `src/routes/dashboard/members/members-table.svelte`
  - Resource: `member_management_view`
  - Shape: paginated member table with exact count, search, status filters, sorting.

- `src/routes/dashboard/members/member-analytics.svelte`
  - Resource: `member_management_view`
  - Shape: total active member count, average age, gender distribution, age distribution, preferred weapon distribution.

- `src/routes/dashboard/members/invitations-table.svelte`
  - Resource: `invitations`
  - Shape: paginated invitation table with estimated count, pending/expired filter, search, sorting.

- `src/routes/dashboard/members/[memberId]/+page.server.ts`
  - Resource: `settings`
  - Read: `value` where `key = insurance_form_link`
  - Domain meaning: insurance form URL shown on a member profile.

- `src/routes/dashboard/+layout.svelte`
  - Resource: `user_profiles`
  - Read: current user's `phone_number` and `customer_id`.

### Workshops

- PRD issue: #142 — Migrate Workshop PostgREST reads to Phoenix APIs.
- Canonical API/domain term: Workshop. `club_activity_*` is persistence vocabulary only.
- Agreed slice boundary: create one Workshop prefactor issue, then three independently demoable read endpoint issues.
- API-driven design applies: write/update the OpenAPI contract before implementation, then generate Phoenix stubs and the TypeScript client.
- Planned endpoints:
  - `GET /api/workshops` — member-safe Workshop collection. Defaults to `planned,published`; optional status filter is constrained to member-safe statuses. Planned DTOs include `interestCount` and `currentUserInterest`; published DTOs include total pending/confirmed `registrationCount` and nullable `currentUserRegistration`. Do not expose other attendee identities.
  - `GET /api/workshops/calendar` — coordinator calendar read. Returns non-cancelled Workshops, preserving current behavior; month/date-window pagination is deferred. DTO includes total `interestCount` and total pending/confirmed `registrationCount`; do not port current-user registration join artifacts.
  - `GET /api/workshops/{id}/attendees` — coordinator attendee/refund management read. Returns one combined payload with Workshop summary, attendees, and refunds. Normalize member/external identities into a domain participant DTO rather than exposing storage joins.
- Workshop coordinator read RBAC: `workshop_coordinator`, `president`, `admin`. Existing registration RLS that grants all-registration visibility to `beginners_coordinator` is confirmed drift; do not mirror it in Phoenix.
- Publish Workshop prefactor and endpoint slices as `ready-for-agent`; the RBAC correction has human confirmation.

- `src/routes/dashboard/workshops/+page.svelte`
  - Resource: `club_activities`
  - Shape: non-cancelled workshops with interest counts, current user's interest, and registration status summaries.

- `src/routes/dashboard/my-workshops/+page.svelte`
  - Resource: `club_activities`
  - Shape: planned workshops with interest counts/current user's interest; published workshops with attendee registrations.

- `src/routes/dashboard/workshops/[id]/attendees/+page.svelte`
  - Resource: `club_activity_registrations`
  - Shape: confirmed/pending attendees for one workshop, including member/external user names.
  - Resource: `club_activity_refunds`
  - Shape: refunds for one workshop via registration join, including member/external user names.

### Inventory

- **Status: ✅ Read migration complete (ALE-93 umbrella; ALE-94–99 endpoints + ALE-100 cleanup).** All six Inventory dashboard reads (overview counts, activity feed, equipment categories, containers, item filter options, item list) now flow through the generated `@dhc/api-client` Phoenix APIs consumed browser-direct via TanStack Query. No `supabase.from(...)` PostgREST reads, Kysely reads, or SvelteKit server-loader DB reads remain in `src/routes/dashboard/inventory/**` list/overview paths. The ALE-100 cleanup removed the orphaned service-layer list read methods (`CategoryService.findMany`, `ItemService.findMany`/`getByContainer`/`getByCategory`, `HistoryService.getRecent`) and the now-unused `ItemFilters` type that were only called by the old `+page.server.ts` reads. Single-record reads (item/container/category detail + edit pages) and writes (`data.remote.ts` create/update/delete) still use the SvelteKit service layer — those are out of scope for the read migration and remain the current system per `src/lib/server/services/AGENTS.md`.
- Planned API/domain terms: Inventory Item, Equipment Category, Container, and Inventory Activity. `inventory_items`, `equipment_categories`, `containers`, and `inventory_history` are persistence vocabulary.
- API-driven design applies: write/update the OpenAPI contract before implementation, then generate Phoenix stubs and the TypeScript client.
- Initial Inventory read RBAC mirrors the current dashboard gate: `quartermaster`, `admin`, `president`.
- Payload/features migration rule: preserve existing read payload fields and behavior unless changing them for consistency with established Phoenix API patterns (for example cursor pagination), domain-model clarity, or more RESTful URI design.
- Agreed slice boundary: create separate, independently demoable endpoint issues plus a cleanup issue, not one large Inventory implementation issue.
- Planned endpoints:
  - `GET /api/inventory/overview` — summary counts only: `summary.containerCount`, `summary.categoryCount`, `summary.itemCount`, `summary.maintenanceCount`. Activity is intentionally split out. ✅ migrated (issue ALE-94): Phoenix `Dhc.Inventory.overview_counts/0` + `DhcWeb.InventoryController.overview/2` behind `:inventory_admin_api`; SvelteKit overview consumes `inventoryOverviewOptions()` via TanStack Query; the four PostgREST count reads were dropped from `src/routes/dashboard/inventory/+page.server.ts` (recent activity stays server-side pending the ALE-95 activity slice).
  - `GET /api/inventory/activity` — Inventory Activity feed, cursor-paginated newest-first by `createdAt desc, id desc`, no total count. Supports `itemId` and `containerId` filters only. Preserves current activity information camelCased: `id`, `action`, `changedBy`, `createdAt`, `itemId`, `oldContainerId`, `newContainerId`, `notes`, `item`, `oldContainer`, `newContainer`. ✅ migrated (issue ALE-95): Phoenix `Dhc.Inventory.list_activity/1` + `DhcWeb.InventoryController.activity/2` behind `:inventory_admin_api`; SvelteKit overview consumes `inventoryActivityOptions()` via TanStack Query; the server-side Kysely read over `inventory_history` was dropped from `src/routes/dashboard/inventory/+page.server.ts`. Cursor pattern mirrors Notifications (forward-only, opaque base64url JSON binding `{limit, itemId, containerId, id, createdAt}`).
  - `GET /api/inventory/categories` — preserves current category list fields, camelCased: `id`, `name`, `description`, `availableAttributes`, `itemCount`. ✅ migrated (issue ALE-96): Phoenix `Dhc.Inventory.list_categories/0` (left-joined `inventory_items` aggregate so empty categories still appear with `itemCount: 0`) + `DhcWeb.InventoryController.categories/2` behind `:inventory_admin_api`; SvelteKit categories page consumes `inventoryCategoriesOptions()` via TanStack Query (browser-direct); the client-side Supabase/PostgREST read over `equipment_categories` (with an `equipment_items(count)` aggregate) was dropped from `src/routes/dashboard/inventory/categories/+page.svelte`. Ordered by `name` asc. Internal timestamps and auth-user refs are not exposed.
  - `GET /api/inventory/containers` — preserves current flat container list fields, camelCased: `id`, `name`, `description`, `parentContainerId`, `parentContainer`, `itemCount`. Do not return a nested tree in the first slice. ✅ migrated (issue ALE-97): Phoenix `Dhc.Inventory.list_containers/0` (flat list with left-joined `count(inventory_items.id)` aggregate so empty containers still appear with `itemCount: 0`; the `parentContainer` `{ id, name }` object is built in Elixir from the same flat list rather than via a self-join, so a missing parent stays `nil`) + `DhcWeb.InventoryController.containers/2` behind `:inventory_admin_api`; SvelteKit containers page consumes `inventoryContainersOptions()` via TanStack Query (browser-direct); the client-side Supabase/PostgREST read over `containers` (with a `parent_container:containers!fk(id, name)` join and an `equipment_items(count)` aggregate) was dropped from `src/routes/dashboard/inventory/containers/+page.svelte`. Ordered by `name` asc. The response is a flat array; the dashboard derives its hierarchy tree client-side from `parentContainerId`/`parentContainer`. Internal timestamps and auth-user refs are not exposed.
  - `GET /api/inventory/items/filters` — replaces the current separate item filter-options server read. Mirrors current `getFilterOptions()` category/container `selectAll()` payloads, camelCased, rather than bundling filter data into the item list. ✅ migrated (issue ALE-98): Phoenix `Dhc.Inventory.filter_options/0` + `DhcWeb.InventoryController.filters/2` behind `:inventory_admin_api`; SvelteKit items page consumes `inventoryFiltersOptions()` via TanStack Query (browser-direct); the server-side `getFilterOptions()` call was dropped from `src/routes/dashboard/inventory/items/+page.server.ts`. Returns `{ data: { categories, containers } }`; each category carries `id`, `name`, `description`, `availableAttributes`, `attributeSchema`; each container carries `id`, `name`, `description`, `parentContainerId`. Both ordered by `name` asc. Internal timestamps and `created_by` auth-user refs are not exposed (the `inserted_at`/`created_at` baseline divergence is out of scope for this slice).
  - `GET /api/inventory/items` — Inventory Item list with cursor pagination for consistency with Phoenix read APIs and `totalCount` for the table. Default/current sort only: `createdAt desc, id desc`; no caller-selected sort in the first slice. Preserve current filters and search: `q` searches item `attributes.name`, Equipment Category name, and Container name; `categoryId`; `containerId`; `maintenanceStatus=all|inMaintenance|available`. Preserve current list fields only, camelCased/domain-shaped: `id`, `quantity`, `maintenanceStatus`, `attributes`, `category`, `container`. ✅ migrated (issue ALE-99): Phoenix `Dhc.Inventory.list_items/1` (bidirectional cursor-paginated, `totalCount` exact `COUNT(*)` matching filters, `nextCursor`/`previousCursor`; fixed `createdAt desc, id desc` sort over `inserted_at` internally; `q` ilike across `attributes->>name`, Equipment Category name, Container name; `categoryId`/`containerId`/`maintenanceStatus` filters) + `DhcWeb.InventoryController.items/2` behind `:inventory_admin_api`; SvelteKit items page consumes `inventoryItemsOptions()` via TanStack Query (browser-direct); the client-side Supabase/PostgREST read over `inventory_items` (joined to `equipment_categories` and `containers`) was dropped from `src/routes/dashboard/inventory/items/+page.svelte`. `maintenanceStatus` is the domain term for the persistence `out_for_maintenance` boolean (`available`/`inMaintenance`); the nested `category`/`container` objects are `{ id, name }` or `null`. Internal auth-user refs and timestamps are not exposed. Cursor pattern mirrors the Members/Waitlist table (opaque base64url JSON binding `{limit, q, categoryId, containerId, maintenanceStatus, id, createdAt, pageDirection}`).
- Endpoint slices can be marked `ready-for-agent`; no remaining human blockers were identified in the design session. Prefactor work should inspect existing baseline migrations/schemas/context support and avoid schema migrations unless the existing DB contract is proven insufficient.

- `src/routes/dashboard/inventory/+page.svelte` ✅ overview counts + activity feed migrated (ALE-94, ALE-95)
  - Resource: `containers`, `equipment_categories`, `inventory_items` (four count reads) + `inventory_history` (recent activity feed)
  - Shape: overview stat cards (Containers, Categories, Items, Maintenance) + recent activity feed
  - Status: count reads replaced by `inventoryOverviewOptions()` and the recent activity feed replaced by `inventoryActivityOptions()` from `@dhc/api-client` (browser-direct via TanStack Query). The server-side Kysely read over `inventory_history` was dropped from `+page.server.ts`.

- `src/routes/dashboard/inventory/categories/+page.svelte` ✅ migrated (ALE-96)
  - Resource: `equipment_categories`
  - Shape: categories with available attributes and item count.
  - Status: the client-side Supabase/PostgREST read over `equipment_categories` (with an `equipment_items(count)` aggregate) was replaced by `inventoryCategoriesOptions()` from `@dhc/api-client` (browser-direct via TanStack Query).

- `src/routes/dashboard/inventory/items/+page.svelte` ✅ migrated (ALE-99)
  - Resource: `inventory_items`
  - Shape: paginated inventory item list with category/container joins, search, category/container/maintenance filters; category + container dropdown options loaded via `inventoryFiltersOptions()` from `@dhc/api-client` (browser-direct via TanStack Query).
  - Status: the client-side Supabase/PostgREST read over `inventory_items` (joined to `equipment_categories` and `containers`, with `count: "exact"` and `.range()` offset pagination) was replaced by `inventoryItemsOptions()` from `@dhc/api-client` (browser-direct via TanStack Query). Pagination switched from page-based offset to bidirectional cursor (`nextCursor`/`previousCursor`) with `totalCount`; `PAGE_SIZE` changed from `20` to `25` (the closest allowed OpenAPI limit enum). `maintenanceStatus` is the domain term for `out_for_maintenance`.

- `src/routes/dashboard/inventory/containers/+page.svelte` ✅ migrated (ALE-97)
  - Resource: `containers`
  - Shape: container hierarchy with parent container and item count.
  - Status: the client-side Supabase/PostgREST read over `containers` (with a `parent_container:containers!fk(id, name)` join and an `equipment_items(count)` aggregate) was replaced by `inventoryContainersOptions()` from `@dhc/api-client` (browser-direct via TanStack Query). The hierarchy tree is still derived client-side from the flat response.

### Notifications

- `src/lib/components/notifications/NotificationCenter.svelte`
  - Tracking issue: #118
  - Resource: `notifications`
  - Shape: unread count and paginated notifications ordered by creation date.
  - Status: reads migrated to `GET /api/notifications`; remaining Supabase usage is command/realtime only.
  - Note: component also marks one/all notifications as read; those are writes/actions.
  - Agreed slice boundary: migrate reads only via `GET /api/notifications`; leave mark-as-read actions and Supabase realtime subscription for later command/realtime slices.

### Authorization / session support

- Slice boundary: handle as its own dedicated vertical slice, separate from Members/Workshops/Inventory.

- `src/routes/dashboard/+layout.server.ts`
  - Resource: `user_roles`
  - Shape: current user's roles for dashboard navigation filtering.

## Migration note

When designing Phoenix APIs, prefer domain endpoints over raw table/view/config endpoints. For example, expose waitlist availability and waitlist entries rather than `settings` or `waitlist_management_view` directly.

For Phoenix reads that are safe to expose to authenticated browsers, prefer direct browser → Phoenix calls through `@dhc/api-client`. The root SvelteKit layout configures the generated HeyAPI client with `configureClient({ baseUrl, getAuthToken })`, loading the current Supabase JWT on every request. Keep `.remote.ts` for SvelteKit-only orchestration, legacy service-layer calls, or commands that still need a SvelteKit server boundary. Cross-origin browser calls require Phoenix CORS origins configured via `CORS_ALLOWED_ORIGINS`; local dev defaults include `http://localhost:5173`.

In practice this means analytics/aggregate reads call the generated `*AnalyticsOptions()` helper from a Svelte component via `createQuery(() => membersAnalyticsOptions())` — no `.remote.ts` `query`, no SvelteKit `authorize()`. Authz for these reads is enforced once, by the Phoenix `RequireAuth` plug on the route's pipeline (e.g. `members_admin_api`, `waitlist_admin_api`). The waitlist analytics (#106) and members analytics (#124) slices both follow this browser-direct pattern. Do **not** re-introduce a redundant server-side `authorize()` gate for reads whose only job is to call a Phoenix endpoint that already enforces RBAC.
