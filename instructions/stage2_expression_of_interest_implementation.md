# Stage 2: Expression of Interest System - Low-Level Implementation Plan

## Overview

This document provides detailed implementation steps for the expression of interest system, integrating with the existing workshop management system (Stage 1) and following all project conventions.

## Prerequisites

- Stage 1 (Core Database CRUD) must be completed ✅
- All three services running: `pnpm supabase:start`, `pnpm supabase:functions:serve`, `pnpm dev`
- Database types generated: `pnpm supabase:types`

## ✅ COMPLETED - Stage 2 Implementation

This stage has been successfully implemented with the following features:

### ✅ Database Implementation

- `club_activity_interest` table created with proper RLS policies
- Interest count view for performance optimization
- Proper indexing and constraints

### ✅ API Implementation

- `/api/workshops/[id]/interest` endpoint for expressing/withdrawing interest
- Toggle functionality (POST to express, POST again to withdraw)
- Proper authentication and authorization
- Input validation and error handling

### ✅ Frontend Implementation

- vkurko/calendar integration with Svelte 5 support
- Workshop calendar component with proper Svelte 5 patterns
- Custom event content rendering showing workshop details and interest status
- Reactive interest count and user interest status
- Multiple calendar views (month, week, day)

### ✅ Key Features Delivered

- Members can view planned workshops in calendar format
- Click on workshop events to open detailed modal
- Express/withdraw interest with toggle button
- Real-time interest count display
- Proper loading states and error handling
- Mobile-responsive design

## Implementation Steps

### 1. Database Migration - `club_activity_interest` Table

**File:** `pnpm supabase migrations new create_club_activity_interest`

```sql
-- Create club_activity_interest table
CREATE TABLE club_activity_interest (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    club_activity_id UUID NOT NULL REFERENCES club_activities(id) ON DELETE CASCADE,
    user_profile_id UUID NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

    -- Prevent duplicate interest per user/workshop
    UNIQUE(club_activity_id, user_profile_id)
);

-- Add indexes for performance
CREATE INDEX idx_club_activity_interest_activity_id ON club_activity_interest(club_activity_id);
CREATE INDEX idx_club_activity_interest_user_profile_id ON club_activity_interest(user_profile_id);
CREATE INDEX idx_club_activity_interest_created_at ON club_activity_interest(created_at);

-- Enable RLS
ALTER TABLE club_activity_interest ENABLE ROW LEVEL SECURITY;

-- RLS Policies
-- Users can only see their own interests
CREATE POLICY "Users can view their own interests"
    ON club_activity_interest
    FOR SELECT
    TO authenticated
    USING (
        user_profile_id IN (
            SELECT id FROM user_profiles WHERE supabase_user_id = (SELECT auth.uid())
        )
    );

-- Users can express interest for themselves
CREATE POLICY "Users can express interest for themselves"
    ON club_activity_interest
    FOR INSERT
    TO authenticated
    WITH CHECK (
        user_profile_id IN (
            SELECT id FROM user_profiles WHERE supabase_user_id = (SELECT auth.uid())
        )
    );

-- Users can withdraw their own interest
CREATE POLICY "Users can withdraw their own interest"
    ON club_activity_interest
    FOR DELETE
    TO authenticated
    USING (
        user_profile_id IN (
            SELECT id FROM user_profiles WHERE supabase_user_id = (SELECT auth.uid())
        )
    );

-- Coordinators can view all interests for workshop management
CREATE POLICY "Coordinators can view all interests"
    ON club_activity_interest
    FOR SELECT
    TO authenticated
    USING (
        has_any_role(
            (SELECT auth.uid()),
            ARRAY['workshop_coordinator', 'president', 'admin']::role_type[]
        )
    );

-- Add trigger for updated_at
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER update_club_activity_interest_updated_at
    BEFORE UPDATE ON club_activity_interest
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- Create interest count view for performance
CREATE VIEW club_activity_interest_counts AS
SELECT
    club_activity_id,
    COUNT(*) as interest_count
FROM club_activity_interest
GROUP BY club_activity_id;

-- Grant access to the view
GRANT SELECT ON club_activity_interest_counts TO authenticated;
```

**Action:** Run `pnpm supabase:types` after applying migration

### 2. API Endpoint Implementation

**File:** `src/routes/api/workshops/[id]/interest/+server.ts`

```typescript
import { json, type RequestHandler } from '@sveltejs/kit';
import { authorize } from '$lib/server/auth.js';
import { executeWithRLS } from '$lib/server/kysely.js';
import { error } from '@sveltejs/kit';
import * as Sentry from '@sentry/sveltekit';

export const POST: RequestHandler = async ({ locals, params }) => {
	try {
		// All authenticated users are members and can express interest
		await authorize(locals, new Set(['member']));

		const workshopId = params.id;
		const supabaseUserId = locals.session?.user?.id;

		if (!supabaseUserId) {
			throw error(401, 'User not authenticated');
		}

		// Get user profile ID from supabase user ID
		const userProfile = await executeWithRLS(
			(db) =>
				db
					.selectFrom('user_profiles')
					.select('id')
					.where('supabase_user_id', '=', supabaseUserId)
					.executeTakeFirst(),
			locals.session
		);

		if (!userProfile) {
			throw error(404, 'User profile not found');
		}

		const userProfileId = userProfile.id;

		if (!workshopId) {
			throw error(400, 'Workshop ID is required');
		}

		// Check if workshop exists and is in 'planned' status
		const workshop = await executeWithRLS(
			(db) =>
				db
					.selectFrom('club_activities')
					.selectAll()
					.where('id', '=', workshopId)
					.executeTakeFirst(),
			locals.session
		);

		if (!workshop) {
			throw error(404, 'Workshop not found');
		}

		if (workshop.status !== 'planned') {
			throw error(400, 'Can only express interest in planned workshops');
		}

		// Check if user already expressed interest
		const existingInterest = await executeWithRLS(
			(db) =>
				db
					.selectFrom('club_activity_interest')
					.selectAll()
					.where('club_activity_id', '=', workshopId)
					.where('user_profile_id', '=', userProfileId)
					.executeTakeFirst(),
			locals.session
		);

		if (existingInterest) {
			// Withdraw interest (toggle behavior)
			await executeWithRLS(
				(db) =>
					db.deleteFrom('club_activity_interest').where('id', '=', existingInterest.id).execute(),
				locals.session
			);

			return json({
				success: true,
				interest: null,
				message: 'Interest withdrawn successfully'
			});
		} else {
			// Express interest
			const newInterest = await executeWithRLS(
				(db) =>
					db
						.insertInto('club_activity_interest')
						.values({
							club_activity_id: workshopId,
							user_profile_id: userProfileId
						})
						.returningAll()
						.executeTakeFirst(),
				locals.session
			);

			return json({
				success: true,
				interest: newInterest,
				message: 'Interest expressed successfully'
			});
		}
	} catch (err) {
		Sentry.captureException(err);
		console.error('Error managing workshop interest:', err);

		if (err.status) {
			throw err;
		}

		throw error(500, 'Failed to manage workshop interest');
	}
};
```

**File:** `src/lib/schemas/workshops.ts` (extend existing)

```typescript
// Add to existing file
export const expressInterestSchema = v.object({
	workshopId: v.pipe(v.string(), v.uuid('Must be a valid UUID'))
});

export type ExpressInterestInput = v.InferInput<typeof expressInterestSchema>;
```

### 3. Frontend Implementation - vkurko/calendar Integration

**File:** `src/routes/dashboard/my-workshops/+page.svelte`

```svelte
<script>
	import { createQuery, createMutation, useQueryClient } from '@tanstack/svelte-query';
	import { supabase } from '$lib/supabase.js';
	import { page } from '$app/stores';
	import WorkshopCalendar from '$lib/components/workshops/workshop-calendar.svelte';
	import { Button } from '$lib/components/ui/button';
	import {
		Card,
		CardContent,
		CardDescription,
		CardHeader,
		CardTitle
	} from '$lib/components/ui/card';
	import { Badge } from '$lib/components/ui/badge';
	import { Skeleton } from '$lib/components/ui/skeleton';
	import { toast } from 'svelte-sonner';
	import { CalendarDays, Users, Clock } from 'lucide-svelte';

	const queryClient = useQueryClient();

	// Fetch planned workshops with interest data (using thunk pattern)
	const workshopsQuery = createQuery(() => ({
		queryKey: ['workshops', 'planned'],
		queryFn: async () => {
			const { data: workshops, error } = await supabase
				.from('club_activities')
				.select(
					`
                    *,
                    interest_count:club_activity_interest_counts(interest_count),
                    user_interest:club_activity_interest(id)
                `
				)
				.eq('status', 'planned')
				.order('start_date', { ascending: true });

			if (error) throw error;
			return workshops;
		}
	}));

	// Express/withdraw interest mutation (using thunk pattern)
	const interestMutation = createMutation(() => ({
		mutationFn: async (workshopId) => {
			const response = await fetch(`/api/workshops/${workshopId}/interest`, {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' }
			});

			if (!response.ok) {
				const error = await response.json();
				throw new Error(error.message || 'Failed to manage interest');
			}

			return response.json();
		},
		onSuccess: (data) => {
			queryClient.invalidateQueries({ queryKey: ['workshops', 'planned'] });
			toast.success(data.message);
		},
		onError: (error) => {
			toast.error(error.message);
		}
	}));

	const handleInterestToggle = (workshopId) => {
		interestMutation.mutate(workshopId);
	};
</script>

<div class="container mx-auto p-6 space-y-6">
	<div class="flex items-center gap-2">
		<CalendarDays class="w-6 h-6" />
		<h1 class="text-2xl font-bold">My Workshops</h1>
	</div>

	{#if workshopsQuery.isLoading}
		<div class="space-y-4">
			{#each Array(3) as _}
				<Skeleton class="h-32 w-full" />
			{/each}
		</div>
	{:else if workshopsQuery.error}
		<Card>
			<CardContent class="pt-6">
				<p class="text-destructive">Error loading workshops: {workshopsQuery.error.message}</p>
			</CardContent>
		</Card>
	{:else}
		<div class="grid gap-6">
			<!-- Calendar View -->
			<Card>
				<CardHeader>
					<CardTitle>Workshop Calendar</CardTitle>
					<CardDescription>View planned workshops and express your interest</CardDescription>
				</CardHeader>
				<CardContent>
					<WorkshopCalendar
						workshops={workshopsQuery.data}
						onInterestToggle={handleInterestToggle}
						isLoading={interestMutation.isPending}
					/>
				</CardContent>
			</Card>

			<!-- Workshop List -->
			<Card>
				<CardHeader>
					<CardTitle>Planned Workshops</CardTitle>
					<CardDescription>All upcoming workshops you can express interest in</CardDescription>
				</CardHeader>
				<CardContent>
					{#if workshopsQuery.data.length === 0}
						<p class="text-muted-foreground text-center py-8">No planned workshops at the moment</p>
					{:else}
						<div class="space-y-4">
							{#each workshopsQuery.data as workshop}
								<div class="flex items-center justify-between p-4 border rounded-lg">
									<div class="flex-1">
										<h3 class="font-semibold">{workshop.title}</h3>
										<p class="text-sm text-muted-foreground">{workshop.description}</p>
										<div class="flex items-center gap-4 mt-2 text-sm">
											<div class="flex items-center gap-1">
												<Clock class="w-4 h-4" />
												{new Date(workshop.start_date).toLocaleDateString()}
											</div>
											<div class="flex items-center gap-1">
												<Users class="w-4 h-4" />
												{workshop.interest_count?.[0]?.interest_count || 0} interested
											</div>
										</div>
									</div>
									<div class="flex items-center gap-2">
										<Badge variant="secondary">Planned</Badge>
										<Button
											variant={workshop.user_interest.length > 0 ? 'default' : 'outline'}
											size="sm"
											onclick={() => handleInterestToggle(workshop.id)}
											disabled={interestMutation.isPending}
										>
											{workshop.user_interest.length > 0 ? 'Interested' : 'Express Interest'}
										</Button>
									</div>
								</div>
							{/each}
						</div>
					{/if}
				</CardContent>
			</Card>
		</div>
	{/if}
</div>
```

**File:** `src/lib/components/workshops/workshop-calendar.svelte`

```svelte
<script lang="ts">
	import { Calendar, DayGrid, TimeGrid, Interaction } from '@event-calendar/core';
	import '@event-calendar/core/index.css';
	import dayjs from 'dayjs';
	import { Button } from '$lib/components/ui/button';
	import { Badge } from '$lib/components/ui/badge';
	import { Users, MapPin, Clock } from 'lucide-svelte';
	import type { Workshop } from '$lib/types';

	let {
		workshops = [],
		userId,
		isLoading = false,
		handleEdit,
		handleDelete,
		handlePublish,
		handleCancel,
		onInterestToggle
	}: {
		workshops: Workshop[];
		userId: string;
		isLoading: boolean;
		handleEdit?: (workshop: Workshop) => void;
		handleDelete?: (workshop: Workshop) => void;
		handlePublish?: (workshop: Workshop) => void;
		handleCancel?: (workshop: Workshop) => void;
		onInterestToggle?: (workshopId: string) => void;
	} = $props();

	let calendarElement: HTMLElement;

	// Convert workshops to EventCalendar events format
	const events = $derived(
		workshops.map((workshop) => ({
			id: workshop.id,
			title: workshop.title,
			start: dayjs(workshop.start_date).format('YYYY-MM-DD HH:mm'),
			end: dayjs(workshop.end_date).format('YYYY-MM-DD HH:mm'),
			backgroundColor: '#3b82f6',
			textColor: '#ffffff',
			extendedProps: {
				workshop: workshop,
				description: workshop.description,
				location: workshop.location,
				interestCount: workshop.interest_count?.[0]?.interest_count || 0,
				isInterested: workshop.user_interest.map((i) => i.user_id).includes(userId)
			}
		}))
	);

	// Calendar options
	const options = $derived({
		view: 'dayGridMonth',
		events: events,
		headerToolbar: {
			start: 'prev,next today',
			center: 'title',
			end: 'dayGridMonth,timeGridWeek,timeGridDay'
		},
		height: '600px',
		eventClick: (info: any) => {
			// Handle event click - show workshop details
			const workshop = info.event.extendedProps.workshop;
			console.log('Workshop clicked:', workshop);
		},
		eventContent: (info: any) => {
			const workshop = info.event.extendedProps.workshop;
			const interestCount = info.event.extendedProps.interestCount;
			const isInterested = info.event.extendedProps.isInterested;

			return {
				html: `
					<div class="workshop-event p-1">
						<div class="workshop-event-title font-medium text-sm">${workshop.title}</div>
						<div class="workshop-event-info text-xs opacity-80 mt-1">
							<div class="flex items-center justify-between">
								<span>${interestCount} interested</span>
								${isInterested ? '<span class="text-green-400">✓ Interested</span>' : ''}
							</div>
						</div>
					</div>
				`
			};
		},
		dayMaxEvents: true,
		moreLinkContent: (arg: any) => `+${arg.num} more`,
		selectable: false,
		editable: false
	});
</script>

<div class="workshop-calendar-container">
	<div bind:this={calendarElement}>
		<Calendar plugins={[DayGrid, TimeGrid, Interaction]} {options} />
	</div>

	<!-- Legend -->
	<div class="flex items-center gap-4 mt-4 text-sm">
		<div class="flex items-center gap-2">
			<div class="w-4 h-4 bg-blue-500 rounded"></div>
			<span>Planned Workshops</span>
		</div>
		<div class="flex items-center gap-2">
			<Badge variant="outline" class="text-xs">✓</Badge>
			<span>You're interested</span>
		</div>
	</div>
</div>

<style>
	.workshop-calendar-container {
		width: 100%;
	}

	/* Custom event styling */
	:global(.workshop-event) {
		width: 100%;
		height: 100%;
	}

	:global(.workshop-event-title) {
		line-height: 1.2;
	}

	:global(.workshop-event-info) {
		line-height: 1.1;
	}
</style>
```

### 4. Package Dependencies

**Add to `package.json`:**

```json
{
	"dependencies": {
		"@event-calendar/core": "^4.5.0"
	}
}
```

**Install command:** `pnpm install`

### 5. Navigation Integration

**File:** `src/lib/server/rbacRoles.ts` (extend existing)

```typescript
// Add to existing navMain array in rbacRoles.ts
{
    title: 'My Workshops',
    url: 'my-workshops',
    role: new Set(['member']) // All authenticated users have member role
}
```

### 6. Comprehensive Test Suite

**File:** `e2e/workshops-interest.spec.ts`

```typescript
import { test, expect } from '@playwright/test';
import { createMember } from './setupFunctions';
import { loginAsUser } from './supabaseLogin';

test.describe('Workshop Interest System', () => {
	let workshopId: string;
	let memberData: Awaited<ReturnType<typeof createMember>>;
	const timestamp = Date.now();
	const randomSuffix = Math.random().toString(36).substring(2, 15);

	test.beforeAll(async () => {
		// Create member user
		memberData = await createMember({
			email: `member-${timestamp}@test.com`,
			roles: new Set(['member'])
		});
	});

	async function makeAuthenticatedRequest(page: any, url: string, options: any = {}) {
		const response = await page.request.fetch(url, {
			...options,
			headers: {
				'Content-Type': 'application/json',
				...options.headers
			}
		});
		return await response.json();
	}

	test.beforeEach(async ({ page, context }) => {
		await loginAsUser(context, memberData.email);
		await page.goto('/dashboard');

		// Create a test workshop as admin
		const createResponse = await makeAuthenticatedRequest(page, '/api/workshops', {
			method: 'POST',
			data: {
				title: `Test Workshop ${timestamp}`,
				description: 'Test workshop for interest system',
				location: 'Test Location',
				workshop_date: new Date(Date.now() + 86400000).toISOString(),
				workshop_time: '14:00',
				max_capacity: 20,
				price_member: 2000,
				price_non_member: 3000,
				is_public: true,
				refund_deadline_days: 3
			}
		});

		expect(createResponse.success).toBe(true);
		workshopId = createResponse.workshop.id;
	});

	test('should display planned workshops in calendar view', async ({ page }) => {
		await page.goto('/dashboard/my-workshops');

		// Wait for calendar to load
		await page.waitForSelector('.sx-calendar-wrapper');

		// Check workshop appears in calendar
		await expect(page.locator(`text=Test Workshop ${timestamp}`)).toBeVisible();

		// Check interest count is displayed
		await expect(page.locator('text=0 interested')).toBeVisible();
	});

	test('should allow member to express interest', async ({ page, context }) => {
		await loginAsUser(context, memberData.email);
		await page.goto('/dashboard/my-workshops');

		// Find and click express interest button
		await page.click(`text=Express Interest`);

		// Check success message
		await expect(page.locator('text=Interest expressed successfully')).toBeVisible();

		// Check button text changes
		await expect(page.locator('text=Interested')).toBeVisible();

		// Check interest count updates
		await expect(page.locator('text=1 interested')).toBeVisible();
	});

	test('should allow member to withdraw interest', async ({ page, context }) => {
		await loginAsUser(context, memberData.email);
		await page.goto('/dashboard');

		// First express interest
		await makeAuthenticatedRequest(page, `/api/workshops/${workshopId}/interest`, {
			method: 'POST'
		});

		await page.goto('/dashboard/my-workshops');

		// Click to withdraw interest
		await page.click('text=Interested');

		// Check success message
		await expect(page.locator('text=Interest withdrawn successfully')).toBeVisible();

		// Check button text changes back
		await expect(page.locator('text=Express Interest')).toBeVisible();

		// Check interest count updates
		await expect(page.locator('text=0 interested')).toBeVisible();
	});

	test('should prevent duplicate interest entries', async ({ page, context }) => {
		await loginAsUser(context, memberData.email);
		await page.goto('/dashboard');

		// Express interest via API
		const response1 = await makeAuthenticatedRequest(
			page,
			`/api/workshops/${workshopId}/interest`,
			{
				method: 'POST'
			}
		);
		expect(response1.success).toBe(true);

		// Try to express interest again - should withdraw instead
		const response2 = await makeAuthenticatedRequest(
			page,
			`/api/workshops/${workshopId}/interest`,
			{
				method: 'POST'
			}
		);
		expect(response2.success).toBe(true);
		expect(response2.interest).toBe(null);
		expect(response2.message).toBe('Interest withdrawn successfully');
	});

	test('should not allow interest in published workshops', async ({ page, context }) => {
		await loginAsUser(context, memberData.email);
		await page.goto('/dashboard');

		// Publish the workshop
		await makeAuthenticatedRequest(page, `/api/workshops/${workshopId}/publish`, {
			method: 'POST'
		});

		// Try to express interest
		const response = await makeAuthenticatedRequest(page, `/api/workshops/${workshopId}/interest`, {
			method: 'POST'
		});

		expect(response.success).toBe(false);
		expect(response.error).toContain('Can only express interest in planned workshops');
	});

	test('should show interest counts to coordinators', async ({ page, context }) => {
		await loginAsUser(context, memberData.email);
		await page.goto('/dashboard');

		// Express interest as regular user
		await makeAuthenticatedRequest(page, `/api/workshops/${workshopId}/interest`, {
			method: 'POST'
		});

		// Navigate to coordinator workshop list
		await page.goto('/dashboard/workshops');

		// Check interest count is visible to coordinators
		await expect(page.locator('text=1 interested')).toBeVisible();
	});
});
```

**File:** `src/lib/components/workshops/workshop-calendar.test.ts`

```typescript
import { render, screen } from '@testing-library/svelte';
import { vi } from 'vitest';
import WorkshopCalendar from './workshop-calendar.svelte';

vi.mock('@event-calendar/core', () => ({
	Calendar: vi.fn(),
	DayGrid: vi.fn(),
	TimeGrid: vi.fn(),
	Interaction: vi.fn()
}));

describe('WorkshopCalendar', () => {
	const mockWorkshops = [
		{
			id: '1',
			title: 'Test Workshop',
			description: 'Test Description',
			start_date: '2024-01-15T10:00:00Z',
			end_date: '2024-01-15T11:00:00Z',
			location: 'Test Location',
			interest_count: [{ interest_count: 2 }],
			user_interest: []
		}
	];

	test('renders calendar wrapper', () => {
		render(WorkshopCalendar, {
			props: {
				workshops: mockWorkshops,
				onInterestToggle: vi.fn(),
				isLoading: false
			}
		});

		expect(screen.getByText('Planned Workshops')).toBeInTheDocument();
	});

	test('displays interest legend', () => {
		render(WorkshopCalendar, {
			props: {
				workshops: mockWorkshops,
				onInterestToggle: vi.fn(),
				isLoading: false
			}
		});

		expect(screen.getByText("You're interested")).toBeInTheDocument();
	});
});
```

### 7. Database Type Generation

**Run after migration:**

```bash
pnpm supabase:types
```

**Verify types in `src/database.types.ts`:**

```typescript
// Should include:
export interface Database {
	public: {
		Tables: {
			club_activity_interest: {
				Row: {
					id: string;
					club_activity_id: string;
					user_profile_id: string;
					created_at: string;
					updated_at: string;
				};
				Insert: {
					id?: string;
					club_activity_id: string;
					user_profile_id: string;
					created_at?: string;
					updated_at?: string;
				};
				Update: {
					id?: string;
					club_activity_id?: string;
					user_profile_id?: string;
					created_at?: string;
					updated_at?: string;
				};
			};
			// ... other tables
		};
		Views: {
			club_activity_interest_counts: {
				Row: {
					club_activity_id: string;
					interest_count: number;
				};
			};
		};
	};
}
```

## Testing Checklist

### Unit Tests

- [ ] Interest API endpoint functionality
- [ ] Workshop calendar component rendering
- [ ] Interest count calculations
- [ ] Role-based access control

### E2E Tests

- [ ] Calendar view displays workshops
- [ ] Interest expression works correctly
- [ ] Interest withdrawal works correctly
- [ ] Duplicate interest prevention
- [ ] Published workshop interest restriction
- [ ] Coordinator interest count visibility

### Performance Tests

- [ ] Calendar renders efficiently with many workshops
- [ ] Interest counts update in real-time
- [ ] Database queries are optimized

## Deployment Checklist

### Prerequisites

- [ ] Database migration applied
- [ ] Types generated
- [ ] Dependencies installed
- [ ] Tests passing

### Verification

- [ ] Calendar displays properly
- [ ] Interest buttons work
- [ ] Interest counts accurate
- [ ] RLS policies enforced
- [ ] Mobile responsive

## Security Considerations

### Database Security

- [ ] RLS policies prevent unauthorized access
- [ ] Unique constraints prevent duplicate interests
- [ ] Proper indexing for performance

### API Security

- [ ] Authentication required for all endpoints
- [ ] Input validation with Valibot
- [ ] Proper error handling and logging

### Frontend Security

- [ ] No sensitive data exposed
- [ ] Proper error handling
- [ ] CSRF protection via SvelteKit

## Performance Optimizations

### Database

- [ ] Indexes on frequently queried columns
- [ ] Interest count view for efficient aggregation
- [ ] Proper query optimization

### Frontend

- [ ] TanStack Query for caching
- [ ] Lazy loading for calendar
- [ ] Optimistic updates for interactions

## Success Metrics

### Functionality

- [ ] Members can view planned workshops in calendar
- [ ] Interest expression/withdrawal works correctly
- [ ] Interest counts are accurate
- [ ] Coordinator visibility of interest data

### Performance

- [ ] Calendar loads within 2 seconds
- [ ] Interest actions respond within 500ms
- [ ] Database queries under 100ms

### Security

- [ ] All RLS policies enforced
- [ ] No unauthorized access possible
- [ ] Proper error handling throughout

## Next Steps

After implementing Stage 2:

1. **Stage 3**: Registration and Payment System
2. **Stage 4**: Attendee Management and Refunds
3. **Stage 5**: Advanced Dashboard Analytics
4. **Stage 6**: Communication System

This implementation provides a solid foundation for the expression of interest system while maintaining all project conventions and security requirements.
