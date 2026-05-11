# Phoenix Backend-First Migration Plan (Supabase DB + Auth)

## Scope Decision (Locked)

- Keep **Supabase Postgres** and **Supabase Auth**.
- Migrate backend concerns from SvelteKit/Supabase Edge to **Phoenix**:
  - API/business logic
  - authorization policy enforcement
  - webhooks
  - queues/jobs/cron
- Do **not** rely on Supabase API, RLS-driven app logic, or Supabase queue/edge runtime.
- Keep existing Svelte UI first, then later migrate selected screens to LiveView + Svelte islands.

---

## High-Level Timeline (10 weeks)

### Weeks 1-2: Phoenix foundation + auth parity

**Goals**
- Phoenix app + Ecto connected to Supabase Postgres
- JWT verification for Supabase access tokens
- role extraction parity with current app metadata roles
- central policy layer replacing current route authorization checks

**Deliverables**
- `GET /api/health`
- `GET /api/me`
- role policy checks equivalent to current sets:
  - `SETTINGS_ROLES`
  - `WORKSHOP_ROLES`
  - `INVENTORY_ROLES`

**Acceptance**
- Svelte can call Phoenix with Supabase token and receive equivalent authz decisions.

---

### Week 3: Members + Settings (first vertical slice)

**Source mapping**
- `src/lib/server/services/members/*`
- `src/lib/server/services/settings/*`
- `src/routes/dashboard/members/data.remote.ts`
- `src/routes/dashboard/members/[memberId]/data.remote.ts`

**Deliverables**
- Members context endpoints (list, detail, update)
- Settings context endpoints (read/update)
- frontend adapter switched for members/settings routes

**Acceptance**
- `/dashboard/members` core flows run against Phoenix in staging.

---

### Week 4: Invitations + signup pricing

**Source mapping**
- `src/lib/server/services/invitations/*`
- `src/routes/dashboard/beginners-workshop/admin.remote.ts`
- `src/routes/(public)/members/signup/[invitationId]/data.remote.ts`
- `src/routes/(public)/members/signup/[invitationId]/pricing.remote.ts`
- `supabase/functions/bulk_invite_with_subscription`

**Deliverables**
- Invitations endpoints + pricing endpoints
- async bulk invite processing via Oban job

**Acceptance**
- invite + signup pricing smoke tests green.

---

### Weeks 5-6: Workshops + Stripe flows

**Source mapping**
- `src/lib/server/services/workshops/*`
- `src/routes/dashboard/my-workshops/registration.remote.ts`
- `src/routes/dashboard/my-workshops/generate.remote.ts`
- `src/routes/(public)/workshops/[id]/register/data.remote.ts`
- public workshop register/confirmation server route behavior

**Deliverables**
- workshops endpoints (publish/cancel/edit)
- attendance/refund endpoints
- member/public registration + payment flows
- Stripe webhook controller in Phoenix

**Acceptance**
- workshop + payment integration tests pass with idempotency guarantees.

---

### Week 7: Inventory domain

**Source mapping**
- `src/lib/server/services/inventory/*`
- `src/routes/dashboard/inventory/items/data.remote.ts`
- `src/routes/dashboard/inventory/containers/data.remote.ts`
- `src/routes/dashboard/inventory/categories/data.remote.ts`

**Deliverables**
- inventory CRUD endpoints + history semantics parity

**Acceptance**
- inventory screens operate through Phoenix adapter only.

---

### Week 8: Jobs / queue / cron replacement

**Replace Supabase functions with Oban**
- `supabase/functions/process-emails`
- `supabase/functions/process-discord`
- `supabase/functions/process-workshop-announcements`
- `supabase/functions/stripe-sync`

**Deliverables**
- Oban workers + Oban Cron schedules
- retry/backoff/idempotency policies

**Acceptance**
- background processing parity in staging with replay tests.

---

### Week 9: hardening + security cleanup

**Goals**
- remove remaining backend mutations from Svelte server layer
- standardize API response/errors
- DB privilege tightening for Phoenix app role
- RLS stance finalized (disabled or passive defense-in-depth)

**Acceptance**
- full regression/E2E + webhook replay suite green.

---

### Week 10: cutover + operations

**Goals**
- production cutover route-by-route (or full flip if stable)
- retire Supabase Edge runtime in delivery path
- runbooks/alerts/dashboards

**Acceptance**
- stable canary + monitored rollout complete.

---

## Phoenix module/context skeletons (repo-aligned)

Suggested umbrella domains mirroring current service layer:

```text
lib/dhc/
  accounts/
    accounts.ex
    user.ex
    member_profile.ex
    role_policy.ex

  members/
    members.ex
    member_query.ex
    member_policy.ex

  invitations/
    invitations.ex
    invitation.ex
    pricing.ex
    invitation_policy.ex

  workshops/
    workshops.ex
    workshop.ex
    registration.ex
    attendance.ex
    refund.ex
    workshop_policy.ex

  inventory/
    inventory.ex
    item.ex
    container.ex
    category.ex
    history.ex
    inventory_policy.ex

  settings/
    settings.ex
    setting.ex
    settings_policy.ex

  billing/
    stripe_client.ex
    subscription_sync.ex
    webhooks/
      stripe_webhook_handler.ex

  jobs/
    workers/
      email_worker.ex
      discord_worker.ex
      workshop_announcement_worker.ex
      stripe_sync_worker.ex

  auth/
    supabase_jwt.ex
    claims.ex
    roles.ex
```

### Context API examples

```elixir
defmodule Dhc.Workshops do
  alias Dhc.Workshops.{Workshop, Registration, Attendance, Refund}

  # Workshop lifecycle
  def list_workshops(filters, actor), do: ...
  def get_workshop!(id, actor), do: ...
  def create_workshop(attrs, actor), do: ...
  def update_workshop(id, attrs, actor), do: ...
  def publish_workshop(id, actor), do: ...
  def cancel_workshop(id, actor), do: ...

  # Registrations
  def toggle_interest(workshop_id, actor), do: ...
  def create_checkout_session(workshop_id, attrs, actor), do: ...
  def complete_registration_from_checkout(session_id, actor_or_system), do: ...
  def cancel_registration(workshop_id, actor), do: ...

  # Attendance/refunds
  def get_attendance(workshop_id, actor), do: ...
  def update_attendance(workshop_id, updates, actor), do: ...
  def get_refunds(workshop_id, actor), do: ...
  def process_refund(registration_id, reason, actor), do: ...
end
```

```elixir
defmodule Dhc.Members do
  def list_members(filters, actor), do: ...
  def get_member!(id, actor), do: ...
  def update_member(id, attrs, actor), do: ...
  def pause_subscription(member_id, pause_until, actor), do: ...
  def resume_subscription(member_id, actor), do: ...
end
```

### Policy pattern (replace RLS-first assumptions)

```elixir
defmodule Dhc.Workshops.Policy do
  def authorize(:publish, actor, _resource), do: has_any_role?(actor, ["workshop_coordinator", "president", "admin"])
  def authorize(:cancel, actor, _resource), do: has_any_role?(actor, ["workshop_coordinator", "president", "admin"])
  def authorize(:toggle_interest, actor, _resource), do: actor.authenticated?
end
```

---

## Phoenix API surface (initial)

Keep JSON contracts close to existing frontend expectations:

```json
{ "success": true, "resource": { ... } }
{ "success": false, "error": "..." }
```

Initial route groups:

- `/api/members/*`
- `/api/settings/*`
- `/api/invitations/*`
- `/api/workshops/*`
- `/api/inventory/*`
- `/api/webhooks/stripe`

---

## Frontend adapter interface (Svelte)

Create a stable abstraction so UI code is backend-agnostic:

`src/lib/backend/types.ts`

```ts
export interface BackendClient {
  members: MembersApi;
  settings: SettingsApi;
  invitations: InvitationsApi;
  workshops: WorkshopsApi;
  inventory: InventoryApi;
}

export interface WorkshopsApi {
  publishWorkshop(workshopId: string): Promise<{ success: true }>;
  cancelWorkshop(workshopId: string): Promise<{ success: true }>;
  toggleInterest(workshopId: string): Promise<{ success: true; isInterested: boolean }>;
  createCheckoutSession(input: {
    workshopId: string;
    returnUrl: string;
  }): Promise<{ success: true; checkoutClientSecret: string }>;
  completeFromCheckout(sessionId: string): Promise<{ success: true }>;
}
```

`src/lib/backend/phoenix-client.ts`

```ts
export function createPhoenixClient(getAccessToken: () => Promise<string | null>): BackendClient {
  async function request<T>(path: string, init?: RequestInit): Promise<T> {
    const token = await getAccessToken();
    const res = await fetch(`${PUBLIC_PHOENIX_API_URL}${path}`, {
      ...init,
      headers: {
        "content-type": "application/json",
        ...(token ? { authorization: `Bearer ${token}` } : {}),
        ...(init?.headers ?? {})
      }
    });
    if (!res.ok) throw new Error(`Request failed: ${res.status}`);
    return (await res.json()) as T;
  }

  return {
    members: { /* ... */ } as MembersApi,
    settings: { /* ... */ } as SettingsApi,
    invitations: { /* ... */ } as InvitationsApi,
    workshops: {
      publishWorkshop: (id) => request(`/api/workshops/${id}/publish`, { method: "POST" }),
      cancelWorkshop: (id) => request(`/api/workshops/${id}/cancel`, { method: "POST" }),
      toggleInterest: (id) => request(`/api/workshops/${id}/interest`, { method: "POST" }),
      createCheckoutSession: (input) => request(`/api/workshops/${input.workshopId}/register/checkout`, { method: "POST", body: JSON.stringify(input) }),
      completeFromCheckout: (sessionId) => request(`/api/workshops/register/complete`, { method: "POST", body: JSON.stringify({ sessionId }) })
    },
    inventory: { /* ... */ } as InventoryApi
  };
}
```

`src/lib/backend/index.ts`

```ts
import { createPhoenixClient } from "./phoenix-client";

export const backend = createPhoenixClient(async () => {
  // pull from current Supabase session flow
  // e.g. event.locals.safeGetSession() server-side or supabase.auth.getSession() client-side
  return null;
});
```

### Migration usage pattern

- Existing UI/actions call `backend.*` methods (not direct `fetch`, not `.remote.ts` directly).
- During migration, methods can be switched per-domain via feature flag.
- Once stable, remove old domain remote handlers.

---

## Cutover strategy

Use per-domain feature flags:

- `BACKEND_MEMBERS=phoenix|legacy`
- `BACKEND_INVITATIONS=phoenix|legacy`
- `BACKEND_WORKSHOPS=phoenix|legacy`
- `BACKEND_INVENTORY=phoenix|legacy`

This enables incremental rollout and rapid rollback by domain.

---

## Top risks + mitigations

1. **Authz drift after dropping RLS-first posture**
   - Build role matrix tests against current behavior.

2. **Stripe idempotency regressions**
   - Add idempotency keys/table for webhook and completion handlers.

3. **Public workshop registration parity**
   - Preserve current 404/full/confirmation contracts before UI changes.

4. **Big-bang frontend rewiring risk**
   - Enforce adapter-only access from UI and migrate per route/domain.

---

## Definition of Done (backend migration)

- All domain operations served by Phoenix API.
- Supabase Edge functions removed from production path.
- Oban replaces queue/cron behavior.
- Svelte frontend uses backend adapter (no direct backend-specific calls in components).
- Regression + E2E + webhook replay tests pass in staging and production canary.
