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

- `src/routes/dashboard/beginners-workshop/waitlist-table.svelte` (migrated)
  - Resource: `waitlist_management_view`
  - Shape: paginated table with exact count
  - Fields: `id,current_position,full_name,email,phone_number,status,age,initial_registration_date,last_contacted,medical_conditions,admin_notes,social_media_consent,guardian_first_name,guardian_last_name,guardian_phone_number,insurance_form_submitted,last_status_change,search_text`
  - Filters: `status != joined`; optional full-text search on `search_text`
  - Status vocabulary: `waiting`, `invited`, `paid`, `deferred`, `cancelled`, `completed`, `no_reply`, `joined`.
  - UI note: component currently has a stale `declined` badge case; canonical status is the database enum above.
  - Sorting: caller-selected column/direction
  - Pagination: cursor-based previous/next via `cursor` URL param; no random page jumps.
  - Note: same component still updates `waitlist.admin_notes` and invokes invitation functions; those are writes/actions, not read migration targets for this slice.

- `src/routes/dashboard/beginners-workshop/workshop-analytics.svelte`
  - Resource: `waitlist_management_view`
  - Reads:
    - total waitlist count: `id`, exact count, `status != joined`, head-only
    - average age: `avg_age:age.avg()`, `status != joined`
    - age distribution: `age,value:age.count()`, `status != joined`, ordered by age
  - Resource: `user_profiles`
  - Reads:
    - gender distribution: `gender,count:gender.count()` where `is_active = false`, `waitlist_id IS NOT NULL`, `supabase_user_id IS NULL`

- `src/routes/(public)/waitlist/+page.server.ts`
  - Resource: `settings`
  - Read: `value` where `key = waitlist_open`
  - Domain meaning: whether the public waitlist accepts new entries.
  - RLS note: `settings` SELECT is authenticated-only, but this route currently uses the service role from a public page.

## Remaining migration inventory

### Members

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

- `src/routes/dashboard/inventory/categories/+page.svelte`
  - Resource: `equipment_categories`
  - Shape: categories with available attributes and item count.

- `src/routes/dashboard/inventory/items/+page.svelte`
  - Resource: `inventory_items`
  - Shape: paginated inventory item list with category/container joins, search, category/container/maintenance filters.

- `src/routes/dashboard/inventory/containers/+page.svelte`
  - Resource: `containers`
  - Shape: container hierarchy with parent container and item count.

### Notifications

- `src/lib/components/notifications/NotificationCenter.svelte`
  - Resource: `notifications`
  - Shape: unread count and paginated notifications ordered by creation date.
  - Note: component also marks one/all notifications as read; those are writes/actions.

### Authorization / session support

- `src/routes/dashboard/+layout.server.ts`
  - Resource: `user_roles`
  - Shape: current user's roles for dashboard navigation filtering.

## Migration note

When designing Phoenix APIs, prefer domain endpoints over raw table/view/config endpoints. For example, expose waitlist availability and waitlist entries rather than `settings` or `waitlist_management_view` directly.

For Phoenix reads that are safe to expose to authenticated browsers, prefer direct browser → Phoenix calls through `@dhc/api-client`. The root SvelteKit layout configures the generated HeyAPI client with `configureClient({ baseUrl, getAuthToken })`, loading the current Supabase JWT on every request. Keep `.remote.ts` for SvelteKit-only orchestration, legacy service-layer calls, or commands that still need a SvelteKit server boundary.
