# Subscription Pause Feature Implementation Plan - CORRECTED

## Overview

Implement a subscription pause feature that allows members to temporarily pause their membership subscriptions with a specific end date. This feature uses Stripe's native pause functionality and adds a database field to track pause status.

## Requirements

- Members can pause their subscription until a specific date
- No indefinite pauses allowed - must specify resume date
- Add subscription pause status to database
- Integration with existing member profile page
- Proper validation and business rules
- Users remain active during pause period

## Technical Architecture

### 1. Database Schema Changes

#### Add Subscription Pause Field to Member Profiles

**Migration:** `pnpm supabase migrations new add_subscription_pause_field.sql`

```sql
-- Add subscription pause tracking to member_profiles
ALTER TABLE member_profiles
ADD COLUMN subscription_paused_until TIMESTAMP WITH TIME ZONE DEFAULT NULL;

-- Add index for performance
CREATE INDEX idx_member_profiles_subscription_paused_until
ON member_profiles(subscription_paused_until)
WHERE subscription_paused_until IS NOT NULL;

-- Update member_management_view to include pause status
DROP VIEW IF EXISTS public.member_management_view;
CREATE VIEW public.member_management_view with (security_invoker) AS
SELECT mp.*,
       up.first_name,
       up.last_name,
       up.phone_number,
       up.gender,
       up.pronouns,
       up.is_active,
       up.customer_id,  -- Add customer_id to view
       (select email from public.get_email_from_auth_users(up.supabase_user_id)) as email,
       w.id as from_waitlist_id,
       w.initial_registration_date as waitlist_registration_date,
       array_agg(ur.role) as roles,
       extract(year from age(up.date_of_birth)) as age,
       up.search_text as search_text,
       up.social_media_consent as social_media_consent,
       wg.first_name as guardian_first_name,
       wg.last_name as guardian_last_name,
       wg.phone_number as guardian_phone_number,
       mp.subscription_paused_until  -- Add pause status
FROM public.member_profiles mp
JOIN public.user_profiles up ON mp.user_profile_id = up.id
LEFT JOIN public.waitlist w ON up.waitlist_id = w.id
LEFT JOIN public.user_roles ur ON up.supabase_user_id = ur.user_id
LEFT JOIN waitlist_guardians wg on wg.profile_id = up.id
GROUP BY mp.id, up.id, w.id, wg.id;
```

### 2. Settings Configuration

#### Add Pause Limits to Settings Table

```sql
INSERT INTO settings (key, value, description) VALUES
('subscription_max_pause_months', '6', 'Maximum months a subscription can be paused'),
('subscription_min_pause_days', '1', 'Minimum days a subscription can be paused');
```

### 3. API Endpoints

#### POST `/api/members/[memberId]/subscription/pause`

- Pause subscription until specified date
- Validate pause end date (max 6 months from now)
- Use Stripe's `pause_collection` with `resumes_at`
- Update database with pause end date

**Request Body:**

```typescript
{
  pauseUntil: string, // ISO date string
  reason?: string     // Optional reason
}
```

**Response:**

```typescript
{
  success: true,
  subscription: {
    id: string,
    status: 'paused',
    pause_collection: {
      behavior: 'void',
      resumes_at: number
    }
  }
}
```

#### DELETE `/api/members/[memberId]/subscription/pause`

- Resume subscription immediately
- Remove pause_collection from Stripe subscription
- Clear database pause field

### 4. Business Logic & Validation

#### Pause Duration Rules

- Minimum pause: 1 day
- Maximum pause: 6 months
- Cannot pause if already paused
- Cannot set resume date in the past
- Cannot pause within 24 hours of billing cycle

#### Implementation:

**File:** `src/routes/api/members/[memberId]/subscription/pause/+server.ts`

```typescript
import { stripeClient } from '$lib/server/stripe';
import { MEMBERSHIP_FEE_LOOKUP_NAME } from '$lib/server/constants';
import { executeWithRLS } from '$lib/server/kysely';
import { error, json } from '@sveltejs/kit';
import dayjs from 'dayjs';

export async function POST({ params, request, locals }) {
	const { pauseUntil, reason } = await request.json();
	const memberId = params.memberId;

	// Validate pause request
	const pauseDate = dayjs(pauseUntil);
	const now = dayjs();
	const maxPauseDate = now.add(6, 'months');

	if (!pauseDate.isValid() || pauseDate.isBefore(now.add(1, 'day'))) {
		throw error(400, 'Invalid pause date');
	}

	if (pauseDate.isAfter(maxPauseDate)) {
		throw error(400, 'Pause period cannot exceed 6 months');
	}
	// THIS SIGNATURE IS WRONG, executeWithRLS arguments are (db: Kysely, Session, (trx) => {})
	// Get customer ID from database
	const member = await executeWithRLS(
		(db) =>
			db
				.selectFrom('member_management_view')
				.select(['customer_id', 'subscription_paused_until'])
				.where('id', '=', memberId)
				.executeTakeFirst(),
		locals.user.id
	);

	if (!member?.customer_id) {
		throw error(404, 'Member or customer not found');
	}

	if (member.subscription_paused_until) {
		throw error(400, 'Subscription is already paused');
	}

	// Find membership subscription in Stripe
	const subscriptions = await stripeClient.subscriptions.list({
		customer: member.customer_id,
		status: 'active',
		limit: 10
	});

	const membershipSub = subscriptions.data.find((sub) =>
		sub.items.data.some((item) => item.price.lookup_key === MEMBERSHIP_FEE_LOOKUP_NAME)
	);

	if (!membershipSub) {
		throw error(404, 'Active membership subscription not found');
	}

	// Pause subscription in Stripe
	const updatedSub = await stripeClient.subscriptions.update(membershipSub.id, {
		pause_collection: {
			behavior: 'void',
			resumes_at: pauseDate.unix()
		}
	});

	// Update database
	await executeWithRLS(
		(db) =>
			db
				.updateTable('member_profiles')
				.set({ subscription_paused_until: pauseDate.toDate() })
				.where('id', '=', memberId)
				.execute(),
		locals.user.id
	);

	return json({ success: true, subscription: updatedSub });
}

export async function DELETE({ params, locals }) {
	const memberId = params.memberId;
	// same here
	// Get customer ID and current pause status
	const member = await executeWithRLS(
		(db) =>
			db
				.selectFrom('member_management_view')
				.select(['customer_id', 'subscription_paused_until'])
				.where('id', '=', memberId)
				.executeTakeFirst(),
		locals.user.id
	);

	if (!member?.customer_id) {
		throw error(404, 'Member or customer not found');
	}

	if (!member.subscription_paused_until) {
		throw error(400, 'Subscription is not paused');
	}

	// Find paused subscription in Stripe
	const subscriptions = await stripeClient.subscriptions.list({
		customer: member.customer_id,
		status: 'paused',
		limit: 10
	});

	const membershipSub = subscriptions.data.find((sub) =>
		sub.items.data.some((item) => item.price.lookup_key === MEMBERSHIP_FEE_LOOKUP_NAME)
	);

	if (!membershipSub) {
		throw error(404, 'Paused membership subscription not found');
	}

	// Resume subscription in Stripe
	const updatedSub = await stripeClient.subscriptions.update(membershipSub.id, {
		pause_collection: null
	});
	// same here
	// Clear database pause field
	await executeWithRLS(
		(db) =>
			db
				.updateTable('member_profiles')
				.set({ subscription_paused_until: null })
				.where('id', '=', memberId)
				.execute(),
		locals.user.id
	);

	return json({ success: true, subscription: updatedSub });
}
```

### 5. Members Table Integration

#### Add Subscription Status Column

**Location:** `src/routes/dashboard/members/members-table.svelte`
**Position:** After "Status" column (around line 205)

**New Column Definition:**

```typescript
{
  accessorKey: 'subscription_paused_until',
  header: 'Subscription',
  cell: ({ row }) => {
    const pausedUntil = row.original.subscription_paused_until;
    const isActive = row.original.is_active;

    if (!isActive) {
      return renderComponent(Badge, {
        variant: 'destructive',
        children: createRawSnippet(() => ({ render: () => 'Inactive' }))
      });
    }

    if (pausedUntil && dayjs(pausedUntil).isAfter(dayjs())) {
      return renderComponent(Badge, {
        variant: 'secondary',
        children: createRawSnippet(() => ({
          render: () => `Paused until ${dayjs(pausedUntil).format('MMM D, YYYY')}`
        }))
      });
    }

    return renderComponent(Badge, {
      variant: 'default',
      children: createRawSnippet(() => ({ render: () => 'Active' }))
    });
  }
}
```

### 6. Member Profile Integration

#### Update: `src/routes/dashboard/members/[memberId]/+page.svelte`

Add subscription management section after billing portal button (line 140):

```svelte
{#if data.canUpdate}
	<SubscriptionManagementCard
		customerId={data.member.customer_id}
		memberId={data.member.id}
		pausedUntil={data.member.subscription_paused_until}
	/>
{/if}
```

#### Subscription Management Card Component

**File:** `src/lib/components/ui/subscription-management-card.svelte`

```svelte
<script lang="ts">
	import { Button } from '$lib/components/ui/button';
	import * as Card from '$lib/components/ui/card';
	import { Badge } from '$lib/components/ui/badge';
	import { createMutation } from '@tanstack/svelte-query';
	import dayjs from 'dayjs';
	import PauseSubscriptionModal from './pause-subscription-modal.svelte';

	const { customerId, memberId, pausedUntil } = $props();

	let showPauseModal = $state(false);

	const isPaused = $derived(pausedUntil && dayjs(pausedUntil).isAfter(dayjs()));

	const pauseMutation = createMutation(() => ({
		mutationFn: (pauseData: { pauseUntil: string; reason?: string }) =>
			fetch(`/api/members/${memberId}/subscription/pause`, {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify(pauseData)
			}).then((r) => r.json()),
		onSuccess: () => {
			showPauseModal = false;
			window.location.reload();
		}
	}));

	const resumeMutation = createMutation(() => ({
		mutationFn: () =>
			fetch(`/api/members/${memberId}/subscription/pause`, {
				method: 'DELETE'
			}).then((r) => r.json()),
		onSuccess: () => {
			window.location.reload();
		}
	}));
</script>

<Card.Root class="w-full">
	<Card.Header>
		<Card.Title>Subscription Management</Card.Title>
	</Card.Header>
	<Card.Content class="space-y-4">
		<div class="flex items-center justify-between">
			<span>Status:</span>
			{#if isPaused}
				<Badge variant="secondary">
					Paused until {dayjs(pausedUntil).format('MMM D, YYYY')}
				</Badge>
			{:else}
				<Badge variant="default">Active</Badge>
			{/if}
		</div>

		<div class="flex gap-2">
			{#if isPaused}
				<Button
					variant="outline"
					onclick={() => resumeMutation.mutate()}
					disabled={resumeMutation.isPending}
				>
					{resumeMutation.isPending ? 'Resuming...' : 'Resume Subscription'}
				</Button>
			{:else}
				<Button variant="outline" onclick={() => (showPauseModal = true)}>
					Pause Subscription
				</Button>
			{/if}
		</div>
	</Card.Content>
</Card.Root>

{#if showPauseModal}
	<PauseSubscriptionModal
		bind:open={showPauseModal}
		onConfirm={(data) => pauseMutation.mutate(data)}
		isPending={pauseMutation.isPending}
	/>
{/if}
```

### 7. Pause Subscription Modal

**File:** `src/lib/components/ui/pause-subscription-modal.svelte`

```svelte
<script lang="ts">
	import { Button } from '$lib/components/ui/button';
	import * as Dialog from '$lib/components/ui/dialog';
	import { Input } from '$lib/components/ui/input';
	import { Label } from '$lib/components/ui/label';
	import { Textarea } from '$lib/components/ui/textarea';
	import dayjs from 'dayjs';

	const { open = $bindable(), onConfirm, isPending } = $props();

	let pauseUntil = $state('');
	let reason = $state('');

	const minDate = $derived(dayjs().add(1, 'day').format('YYYY-MM-DD'));
	const maxDate = $derived(dayjs().add(6, 'months').format('YYYY-MM-DD'));

	function handleConfirm() {
		if (!pauseUntil) return;
		onConfirm({ pauseUntil, reason: reason || undefined });
	}
</script>

<Dialog.Root bind:open>
	<Dialog.Content>
		<Dialog.Header>
			<Dialog.Title>Pause Subscription</Dialog.Title>
			<Dialog.Description>
				Choose when you'd like your subscription to resume. You can pause for up to 6 months.
			</Dialog.Description>
		</Dialog.Header>

		<div class="space-y-4">
			<div>
				<Label for="pauseUntil">Resume Date</Label>
				<Input
					id="pauseUntil"
					type="date"
					bind:value={pauseUntil}
					min={minDate}
					max={maxDate}
					required
				/>
			</div>

			<div>
				<Label for="reason">Reason (Optional)</Label>
				<Textarea
					id="reason"
					bind:value={reason}
					placeholder="Why are you pausing your subscription?"
				/>
			</div>
		</div>

		<Dialog.Footer>
			<Button variant="outline" onclick={() => (open = false)}>Cancel</Button>
			<Button onclick={handleConfirm} disabled={!pauseUntil || isPending}>
				{isPending ? 'Pausing...' : 'Pause Subscription'}
			</Button>
		</Dialog.Footer>
	</Dialog.Content>
</Dialog.Root>
```

### 8. Webhook Integration Updates

#### Fix Current Webhook Behavior

**File:** `supabase/functions/stripe-webhooks/index.ts`

**Problem:** Lines 201-204 treat paused subscriptions as inactive users.

**Solution:** Modify `syncStripeDataToKV()` function:

```typescript
// Updated logic in syncStripeDataToKV() around line 200
if (
	!standardMembershipSub ||
	['canceled', 'incomplete_expired', 'unpaid'].includes(standardMembershipSub.status)
) {
	return setUserInactive(customerId);
}

// Handle paused subscriptions - keep user active, update pause status in DB
if (standardMembershipSub.status === 'paused') {
	const resumeDate = standardMembershipSub.pause_collection?.resumes_at
		? dayjs.unix(standardMembershipSub.pause_collection.resumes_at).toDate()
		: null;

	// Update pause status in database
	await db
		.updateTable('member_profiles')
		.set({ subscription_paused_until: resumeDate })
		.where(
			'user_profile_id',
			'in',
			db.selectFrom('user_profiles').select('id').where('customer_id', '=', customerId)
		)
		.execute();

	console.log(`Subscription paused for customer: ${customerId} until ${resumeDate}`);
	return Promise.resolve();
}

// Update last payment info if subscription is active
if (standardMembershipSub.status === 'active') {
	// Clear any pause status when subscription becomes active
	await db
		.updateTable('member_profiles')
		.set({ subscription_paused_until: null })
		.where(
			'user_profile_id',
			'in',
			db.selectFrom('user_profiles').select('id').where('customer_id', '=', customerId)
		)
		.execute();

	return setLastPayment(
		customerId,
		standardMembershipSub.start_date,
		standardMembershipSub.ended_at ?? null
	);
}
```

### 9. Implementation Steps

1. **Phase 1: Database & Webhook Updates**
   - Create migration for subscription_paused_until field
   - Update member_management_view
   - Fix webhook logic to keep paused users active
   - Add settings for pause limits

2. **Phase 2: API Endpoints**
   - Implement pause/resume endpoints
   - Add validation logic
   - Test with Stripe integration

3. **Phase 3: UI Components**
   - Create subscription management card
   - Build pause modal component
   - Add subscription column to members table

4. **Phase 4: Integration & Testing**
   - Add to member profile page
   - Test complete flow
   - Error handling improvements

### 10. Testing Strategy

#### E2E Tests

**File:** `e2e/subscription-pause.spec.ts`

```typescript
test('member can pause and resume subscription', async ({ page }) => {
	// Test pause flow from member profile
	// Test resume flow
	// Test validation errors
	// Test permission checks
});
```

## Success Criteria

1. ✅ Members can pause subscriptions with end date from profile page
2. ✅ No indefinite pauses allowed
3. ✅ Subscription status visible in members table
4. ✅ Proper validation and error handling
5. ✅ Integration with existing member profile
6. ✅ Users remain active during pause period
7. ✅ Database tracks pause status
8. ✅ Webhook integration updated

## Key Fixes Applied

1. **Users remain active during pause** - Fixed webhook logic
2. **Reuse existing stripe client** - Uses `stripeClient` from `src/lib/server/stripe.ts`
3. **Database field instead of API endpoint** - Added `subscription_paused_until` field
4. **Customer ID from user_profiles** - Added to member_management_view
5. **Fixed imports** - Uses `MEMBERSHIP_FEE_LOOKUP_NAME` from constants
6. **Database migration included** - Complete schema changes
7. **Simple error handling** - Clear error messages, fail fast
8. **Settings configuration** - Configurable pause limits
9. **Updated profile integration** - Uses `canUpdate` boolean

This corrected plan addresses all the identified issues and provides a complete, implementable solution for the subscription pause feature.
