# Remote Functions Migration Plan

**Created**: 2026-01-05  
**Status**: In Progress (Phase 1, 2, 3, 4, 6 complete)  
**Related**: Post-Superforms migration, Service Layer Pattern

## Executive Summary

**Current State**: 13 API routes under `src/routes/api/` handling workshops, members, admin, and signup operations.

**Target State**: Replace with SvelteKit Remote Functions (`.remote.ts` files) providing type-safe client-server communication.

**Prerequisites Already Met**:
- `remoteFunctions: true` enabled in `svelte.config.js`
- `async: true` compiler option enabled
- Service layer pattern established in `src/lib/server/services/`
- Valibot schemas already in use

---

## API Routes Inventory

| Current Route | Method(s) | Purpose | Consumer(s) |
|---------------|-----------|---------|-------------|
| `/api/admin/invite-link` | POST | Resend invitation emails | invitations-table, waitlist-table |
| `/api/members/[memberId]/subscription/pause` | POST, DELETE | Pause/resume Stripe subscriptions | member detail page |
| `/api/signup/plan-pricing/[invitationId]` | GET, POST | Get pricing with optional coupon | payment-form |
| `/api/workshops/generate` | POST | AI workshop generation | quick-create-workshop |
| `/api/workshops/[id]` | DELETE | Delete workshop | workshop-event-modal |
| `/api/workshops/[id]/attendance` | GET, PUT | Manage attendance | attendee-manager |
| `/api/workshops/[id]/cancel` | POST | Cancel workshop | workshop-event-modal |
| `/api/workshops/[id]/interest` | POST | Toggle interest | my-workshops page |
| `/api/workshops/[id]/publish` | POST | Publish workshop | workshop-event-modal |
| `/api/workshops/[id]/refunds` | GET, POST | Manage refunds | attendee-manager, cancellation-dialog |
| `/api/workshops/[id]/register` | DELETE | Cancel registration | workshop-cancellation-dialog |
| `/api/workshops/[id]/register/payment-intent` | POST | Create Stripe payment intent | workshop-express-checkout |
| `/api/workshops/[id]/register/complete` | POST | Complete registration | workshop-express-checkout |

---

## Remote Functions Overview

SvelteKit Remote Functions provide three main primitives:

- **`query`**: Read-only operations (GET-like)
- **`command`**: Mutations not tied to forms
- **`form`**: Form submissions with progressive enhancement

All use Valibot schemas for input validation and provide full type safety between client and server.

### Import Pattern
```typescript
// In .remote.ts file (server)
import { command, query, form, getRequestEvent } from '$app/server';

// In consumer (client)
import { myCommand, myQuery } from './path/to/file.remote';
```

---

## Migration Strategy

### Phase 1: Workshop Management (Coordinator Actions)

**Priority**: High  
**File**: `src/lib/server/services/workshops/workshops.remote.ts`

```typescript
import { command, query, getRequestEvent } from '$app/server';
import * as v from 'valibot';
import { authorize } from '$lib/server/auth';
import { WORKSHOP_ROLES } from '$lib/server/roles';
import { createWorkshopService, createAttendanceService, createRefundService } from '.';

// DELETE workshop
export const deleteWorkshop = command(
  v.pipe(v.string(), v.uuid()),
  async (workshopId) => {
    const { locals, platform } = getRequestEvent();
    const session = await authorize(locals, WORKSHOP_ROLES);
    const service = createWorkshopService(platform!, session);
    await service.delete(workshopId);
    return { success: true };
  }
);

// PUBLISH workshop
export const publishWorkshop = command(
  v.pipe(v.string(), v.uuid()),
  async (workshopId) => {
    const { locals, platform } = getRequestEvent();
    const session = await authorize(locals, WORKSHOP_ROLES);
    const service = createWorkshopService(platform!, session);
    const workshop = await service.publish(workshopId);
    return { success: true, workshop };
  }
);

// CANCEL workshop
export const cancelWorkshop = command(
  v.pipe(v.string(), v.uuid()),
  async (workshopId) => {
    const { locals, platform } = getRequestEvent();
    const session = await authorize(locals, WORKSHOP_ROLES);
    const service = createWorkshopService(platform!, session);
    const workshop = await service.cancel(workshopId);
    return { success: true, workshop };
  }
);

// GET attendance
export const getWorkshopAttendance = query(
  v.pipe(v.string(), v.uuid()),
  async (workshopId) => {
    const { locals, platform } = getRequestEvent();
    const session = await authorize(locals, WORKSHOP_ROLES);
    const service = createAttendanceService(platform!, session);
    return await service.getWorkshopAttendance(workshopId);
  }
);

// UPDATE attendance
export const updateAttendance = command(
  v.object({
    workshopId: v.pipe(v.string(), v.uuid()),
    attendance_updates: v.array(v.object({
      registration_id: v.pipe(v.string(), v.uuid()),
      attendance_status: v.picklist(['attended', 'no_show', 'excused', 'pending']),
      notes: v.optional(v.string())
    }))
  }),
  async ({ workshopId, attendance_updates }) => {
    const { locals, platform } = getRequestEvent();
    const session = await authorize(locals, WORKSHOP_ROLES);
    const service = createAttendanceService(platform!, session);
    return await service.updateAttendance(workshopId, attendance_updates);
  }
);

// GET refunds for workshop
export const getWorkshopRefunds = query(
  v.pipe(v.string(), v.uuid()),
  async (workshopId) => {
    const { locals, platform } = getRequestEvent();
    const session = await authorize(locals, WORKSHOP_ROLES);
    const service = createRefundService(platform!, session);
    return await service.getWorkshopRefunds(workshopId);
  }
);

// PROCESS refund (coordinator action)
export const processRefund = command(
  v.object({
    registration_id: v.pipe(v.string(), v.uuid()),
    reason: v.string()
  }),
  async ({ registration_id, reason }) => {
    const { locals, platform } = getRequestEvent();
    const session = await authorize(locals, WORKSHOP_ROLES);
    const service = createRefundService(platform!, session);
    return await service.processRefund(registration_id, reason);
  }
);
```

**Replaces**:
- `src/routes/api/workshops/[id]/+server.ts` (DELETE)
- `src/routes/api/workshops/[id]/publish/+server.ts`
- `src/routes/api/workshops/[id]/cancel/+server.ts`
- `src/routes/api/workshops/[id]/attendance/+server.ts`
- `src/routes/api/workshops/[id]/refunds/+server.ts` (coordinator POST)

---

### Phase 2: Workshop Registration (Member Actions)

**Priority**: High  
**File**: `src/lib/server/services/workshops/registration.remote.ts`

```typescript
import { command, getRequestEvent } from '$app/server';
import * as v from 'valibot';
import { error } from '@sveltejs/kit';
import { createRegistrationService } from '.';

export const toggleInterest = command(
  v.pipe(v.string(), v.uuid()),
  async (workshopId) => {
    const { locals, platform } = getRequestEvent();
    const { session } = await locals.safeGetSession();
    if (!session) error(401, 'Unauthorized');
    
    const service = createRegistrationService(platform!, session);
    const result = await service.toggleInterest(workshopId);
    return { success: true, ...result };
  }
);

export const createPaymentIntent = command(
  v.object({
    workshopId: v.pipe(v.string(), v.uuid()),
    amount: v.number(),
    currency: v.optional(v.string(), 'eur'),
    customerId: v.optional(v.string())
  }),
  async (input) => {
    const { locals, platform } = getRequestEvent();
    const { session } = await locals.safeGetSession();
    if (!session) error(401, 'Unauthorized');
    
    const service = createRegistrationService(platform!, session);
    const result = await service.createPaymentIntent(input);
    return { success: true, ...result };
  }
);

export const completeRegistration = command(
  v.object({
    workshopId: v.pipe(v.string(), v.uuid()),
    paymentIntentId: v.string()
  }),
  async (input) => {
    const { locals, platform } = getRequestEvent();
    const { session } = await locals.safeGetSession();
    if (!session) error(401, 'Unauthorized');
    
    const service = createRegistrationService(platform!, session);
    const registration = await service.completeRegistration(input);
    return { success: true, registration };
  }
);

export const cancelRegistration = command(
  v.pipe(v.string(), v.uuid()),
  async (workshopId) => {
    const { locals, platform } = getRequestEvent();
    const { session } = await locals.safeGetSession();
    if (!session) error(401, 'Unauthorized');
    
    const service = createRegistrationService(platform!, session);
    const result = await service.cancelRegistration(workshopId);
    return { success: true, ...result };
  }
);
```

**Replaces**:
- `src/routes/api/workshops/[id]/interest/+server.ts`
- `src/routes/api/workshops/[id]/register/+server.ts` (DELETE)
- `src/routes/api/workshops/[id]/register/payment-intent/+server.ts`
- `src/routes/api/workshops/[id]/register/complete/+server.ts`

---

### Phase 3: Admin Functions

**Priority**: Medium  
**File**: `src/lib/server/services/invitations/admin.remote.ts`

> **NOTE**: Add `resendInvitations(emails)` and `bulkDelete(ids)` methods to `InvitationService` first.

```typescript
import { command, getRequestEvent } from '$app/server';
import * as v from 'valibot';
import { authorize } from '$lib/server/auth';
import { SETTINGS_ROLES } from '$lib/server/roles';
import { createInvitationService } from '.';

export const resendInvitations = command(
  v.object({
    emails: v.pipe(v.array(v.pipe(v.string(), v.email())), v.minLength(1))
  }),
  async ({ emails }) => {
    const { locals, platform } = getRequestEvent();
    const session = await authorize(locals, SETTINGS_ROLES);
    
    const service = createInvitationService(platform!, session);
    const result = await service.resendInvitations(emails);
    return { success: true, ...result };
  }
);

export const deleteInvitations = command(
  v.pipe(v.array(v.pipe(v.string(), v.uuid())), v.minLength(1)),
  async (invitationIds) => {
    const { locals, platform } = getRequestEvent();
    const session = await authorize(locals, SETTINGS_ROLES);
    
    const service = createInvitationService(platform!, session);
    await service.bulkDelete(invitationIds);
    return { success: true };
  }
);
```

**Replaces**:
- `src/routes/api/admin/invite-link/+server.ts`

**Service Methods to Add** (`InvitationService`):
```typescript
async resendInvitations(emails: string[]): Promise<{ succeeded: number; failed: number }> {
  // Find pending invitations and send emails
}

async bulkDelete(invitationIds: string[]): Promise<void> {
  // Delete multiple invitations
}
```

---

### Phase 4: Member Subscription Management

**Priority**: Medium  
**File**: `src/lib/server/services/members/subscription.remote.ts`

> **NOTE**: Create a new `SubscriptionService` or add `pauseSubscription(memberId, pauseUntil)` and `resumeSubscription(memberId)` methods to `ProfileService`.

```typescript
import { command, getRequestEvent } from '$app/server';
import * as v from 'valibot';
import dayjs from 'dayjs';
import { error } from '@sveltejs/kit';
import { authorize } from '$lib/server/auth';
import { SETTINGS_ROLES } from '$lib/server/roles';
import { createSubscriptionService } from '.';

export const pauseSubscription = command(
  v.object({
    memberId: v.pipe(v.string(), v.uuid()),
    pauseUntil: v.pipe(
      v.string(),
      v.transform((str) => new Date(str)),
      v.check((date) => {
        const pauseDate = dayjs(date);
        const now = dayjs();
        return pauseDate.isAfter(now.add(1, 'day')) && pauseDate.isBefore(now.add(6, 'months'));
      }, 'Pause date must be between 1 day and 6 months from now')
    )
  }),
  async ({ memberId, pauseUntil }) => {
    const { locals, platform } = getRequestEvent();
    const { session } = await locals.safeGetSession();
    if (!session) error(401, 'Unauthorized');
    
    if (session.user.id !== memberId) {
      await authorize(locals, SETTINGS_ROLES);
    }
    
    const service = createSubscriptionService(platform!, session);
    const subscription = await service.pause(memberId, pauseUntil);
    return { success: true, subscription };
  }
);

export const resumeSubscription = command(
  v.pipe(v.string(), v.uuid()),
  async (memberId) => {
    const { locals, platform } = getRequestEvent();
    const { session } = await locals.safeGetSession();
    if (!session) error(401, 'Unauthorized');
    
    if (session.user.id !== memberId) {
      await authorize(locals, SETTINGS_ROLES);
    }
    
    const service = createSubscriptionService(platform!, session);
    const subscription = await service.resume(memberId);
    return { success: true, subscription };
  }
);
```

**Replaces**:
- `src/routes/api/members/[memberId]/subscription/pause/+server.ts`

**Service to Create** (`SubscriptionService`):
```typescript
export class SubscriptionService {
  async pause(memberId: string, pauseUntil: Date): Promise<Stripe.Subscription> {
    // Get member, pause Stripe subscription, update local DB
  }
  
  async resume(memberId: string): Promise<Stripe.Subscription> {
    // Get member, resume Stripe subscription, update local DB
  }
}
```

---

### Phase 5: Signup Pricing

**Priority**: Medium  
**File**: `src/routes/(public)/members/signup/[invitationId]/pricing.remote.ts`

> **NOTE**: Create a `PricingService` in `src/lib/server/services/invitations/` first with `getPricingDetails(userId, couponCode?)` method.

```typescript
import { query, command, getRequestEvent } from '$app/server';
import * as v from 'valibot';
import { error } from '@sveltejs/kit';
import { createPricingService } from '$lib/server/services/invitations';

export const getPricing = query(
  v.pipe(v.string(), v.uuid()),
  async (invitationId) => {
    const { platform } = getRequestEvent();
    const service = createPricingService(platform!);
    return await service.getPricingForInvitation(invitationId);
  }
);

export const applyCoupon = command(
  v.object({
    invitationId: v.pipe(v.string(), v.uuid()),
    code: v.string()
  }),
  async ({ invitationId, code }) => {
    const { platform } = getRequestEvent();
    const service = createPricingService(platform!);
    return await service.getPricingForInvitation(invitationId, code);
  }
);
```

**Replaces**:
- `src/routes/api/signup/plan-pricing/[invitationId]/+server.ts`

**Service to Create** (`PricingService`):
```typescript
export class PricingService {
  async getPricingForInvitation(invitationId: string, couponCode?: string): Promise<PricingInfo> {
    // 1. Validate invitation exists and is pending
    // 2. Get user profile with customer_id
    // 3. Create invoice previews with Stripe
    // 4. Apply coupon if provided (validate with promotionCodes.list)
    // 5. Return calculated pricing info
  }
}
```

---

### Phase 6: Workshop Generation (AI)

**Priority**: Low  
**File**: `src/lib/server/services/workshops/generate.remote.ts`

```typescript
import { command, getRequestEvent } from '$app/server';
import * as v from 'valibot';
import { authorize } from '$lib/server/auth';
import { WORKSHOP_ROLES } from '$lib/server/roles';
import { generateWorkshopData, coerceToCreateWorkshopSchema } from '$lib/server/workshop-generator';

export const generateWorkshop = command(
  v.object({
    prompt: v.pipe(v.string(), v.nonEmpty(), v.maxLength(1000))
  }),
  async ({ prompt }) => {
    const { locals, request } = getRequestEvent();
    await authorize(locals, WORKSHOP_ROLES);
    
    const result = await generateWorkshopData(prompt, request.signal);
    const coerced = coerceToCreateWorkshopSchema(result.object);
    
    if (!coerced.success) {
      return { success: false, error: 'Generated data is invalid' };
    }
    
    return { success: true, data: coerced.output };
  }
);
```

**Replaces**:
- `src/routes/api/workshops/generate/+server.ts`

---

## Consumer Migration Examples

### Before (fetch-based)

```typescript
// In workshop-event-modal.svelte
const deleteMutation = createMutation(() => ({
  mutationFn: async (workshopId: string) => {
    const response = await fetch(`/api/workshops/${workshopId}`, {
      method: 'DELETE'
    });
    if (!response.ok) throw new Error('Failed to delete workshop');
    return response.json();
  },
  onSuccess: () => {
    queryClient.invalidateQueries({ queryKey: ['workshops'] });
    toast.success('Workshop deleted successfully');
  },
  onError: (error) => {
    toast.error(`Failed to delete workshop: ${error.message}`);
  }
}));
```

### After (remote function)

```typescript
// In workshop-event-modal.svelte
import { deleteWorkshop } from '$lib/server/services/workshops/workshops.remote';

const deleteMutation = createMutation(() => ({
  mutationFn: async (workshopId: string) => {
    return await deleteWorkshop(workshopId);
  },
  onSuccess: () => {
    queryClient.invalidateQueries({ queryKey: ['workshops'] });
    toast.success('Workshop deleted successfully');
  },
  onError: (error) => {
    toast.error(`Failed to delete workshop: ${error.message}`);
  }
}));
```

### Simplest Pattern (direct call)

```svelte
<script>
  import { deleteWorkshop } from '$lib/server/services/workshops/workshops.remote';
  import { useQueryClient } from '@tanstack/svelte-query';
  import { toast } from 'svelte-sonner';

  const queryClient = useQueryClient();
  
  async function handleDelete(workshopId: string) {
    try {
      await deleteWorkshop(workshopId);
      queryClient.invalidateQueries({ queryKey: ['workshops'] });
      toast.success('Workshop deleted');
    } catch (error) {
      toast.error(error.message);
    }
  }
</script>

<button onclick={() => handleDelete(workshop.id)}>Delete</button>
```

---

## File Structure After Migration

```
src/lib/server/services/
├── workshops/
│   ├── index.ts                    # Existing service exports
│   ├── workshop.service.ts         # Existing service class
│   ├── attendance.service.ts       # Existing service class
│   ├── refund.service.ts           # Existing service class
│   ├── workshops.remote.ts         # Coordinator actions
│   ├── registration.remote.ts      # Member registration
│   └── generate.remote.ts          # AI generation
├── members/
│   ├── index.ts
│   ├── member.service.ts
│   ├── subscription.service.ts     # Subscription pause/resume service
│   └── subscription.remote.ts      # Pause/resume remote functions
├── invitations/
│   ├── index.ts
│   └── admin.remote.ts             # Resend invitations, delete invitations

src/routes/(public)/members/signup/[invitationId]/
├── +page.svelte
├── +page.server.ts
├── data.remote.ts                  # Existing
└── pricing.remote.ts               # NEW: Pricing queries
```

---

## Migration Checklist

| Phase | Remote File | Replaces | Priority | Status |
|-------|-------------|----------|----------|------|
| 1 | `workshops.remote.ts` | `/api/workshops/[id]`, `/publish`, `/cancel`, `/attendance`, `/refunds` | High | [x]  |
| 2 | `registration.remote.ts` | `/interest`, `/register/*` | High | [x]  |
| 3 | `admin.remote.ts` | `/api/admin/invite-link` | Medium | [x]  |
| 4 | `subscription.remote.ts` | `/api/members/[memberId]/subscription/pause` | Medium | [x]  |
| 5 | `pricing.remote.ts` | `/api/signup/plan-pricing/[invitationId]` | Medium | [x]  |
| 6 | `generate.remote.ts` | `/api/workshops/generate` | Low | [x]  |

---

## Key Patterns

### 1. Authorization
```typescript
const { locals, platform } = getRequestEvent();
// For role-based access
const session = await authorize(locals, WORKSHOP_ROLES);
// For authenticated users only
const { session } = await locals.safeGetSession();
if (!session) error(401, 'Unauthorized');
```

### 2. Validation
First argument to `command`/`query` is always a Valibot schema:
```typescript
export const myCommand = command(
  v.object({ id: v.pipe(v.string(), v.uuid()) }), // Schema
  async ({ id }) => { /* handler */ }             // Handler receives validated data
);
```

### 3. Error Handling
Use SvelteKit's `error()` for HTTP errors:
```typescript
import { error } from '@sveltejs/kit';
if (!workshop) error(404, 'Workshop not found');
```

### 4. Service Layer Integration
Instantiate services with factory functions:
```typescript
const service = createWorkshopService(platform!, session);
const result = await service.publish(workshopId);
```

> **IMPORTANT**: Remote functions MUST use the service layer. Direct `executeWithRLS` or `getKyselyClient` usage is forbidden in `.remote.ts` files. If a service method doesn't exist, add it to the appropriate service first.

---

## Testing Strategy

1. **Unit Tests**: Test remote functions in isolation with mocked dependencies
2. **Integration Tests**: Test full flow from client call to database
3. **E2E Tests**: Existing Playwright tests should continue to work (test behavior, not implementation)

---

## Rollback Plan

Keep API routes until remote functions are fully tested and deployed. Remove API routes only after:
1. All consumers migrated to remote functions
2. E2E tests passing
3. Production monitoring shows no issues for 1 week

---

## Notes

- Remote functions are automatically tree-shaken - unused exports don't increase bundle size
- Error boundaries work the same as with API routes
- TanStack Query cache invalidation patterns remain unchanged
- Progressive enhancement via `form()` is available for forms that need it
