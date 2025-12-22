# Step 5a: Migrate Workshop Form Component

## Overview

The `workshop-form.svelte` component is a complex shared form used for both creating and editing workshops. This document provides a detailed migration plan from Superforms to SvelteKit Remote Functions.

## Complexity Analysis

### Current Features
- **Shared component**: Used by `/dashboard/workshops/create` and `/dashboard/workshops/[id]/edit`
- **Dual schemas**: `CreateWorkshopSchema` (full validation) and `UpdateWorkshopSchema` (partial)
- **Complex date handling**: Uses `dayjs`, `@internationalized/date`, and custom `Calendar25` component
- **Data transformations**: Dates → ISO strings, prices → cents
- **Conditional field visibility**: `price_non_member` only visible when `is_public` is true
- **Conditional field disabling**: Based on `workshopStatus`, `workshopEditable`, `priceEditingDisabled`
- **Cross-field validation**: `workshop_end_date` must be after `workshop_date`
- **Success callbacks**: `onSuccess` prop for navigation after submission

### Files Involved
- `src/lib/components/workshop-form.svelte` - Main form component
- `src/lib/server/services/workshops/workshop.service.ts` - Service with schemas
- `src/routes/dashboard/workshops/create/+page.server.ts` - Create action
- `src/routes/dashboard/workshops/[id]/edit/+page.server.ts` - Edit action

---

## Step 1: Create Workshop Client Schema

Create a new schema file for client-side form validation. This schema uses `Date` objects for dates (as the UI components work with dates).

**File**: `src/lib/schemas/workshop.ts`

```typescript
import * as v from 'valibot';
import dayjs from 'dayjs';

// ============================================================================
// Base Schema (shared fields between create and update)
// ============================================================================

const isToday = (date: Date) => dayjs(date).isSame(dayjs(), 'day');

/**
 * Base workshop schema for client-side validation.
 * Uses Date objects for workshop_date and workshop_end_date.
 */
export const BaseWorkshopClientSchema = v.object({
	title: v.pipe(v.string(), v.minLength(1, 'Title is required'), v.maxLength(255)),
	description: v.optional(v.string(), ''),
	location: v.pipe(v.string(), v.minLength(1, 'Location is required')),
	workshop_date: v.pipe(
		v.date('Workshop date is required'),
		v.check((date) => !isToday(date), 'Workshop cannot be scheduled for today')
	),
	workshop_end_date: v.date('Workshop end date is required'),
	max_capacity: v.pipe(v.number(), v.minValue(1, 'Capacity must be at least 1')),
	price_member: v.pipe(v.number(), v.minValue(0, 'Price cannot be negative')),
	price_non_member: v.optional(v.pipe(v.number(), v.minValue(0, 'Price cannot be negative'))),
	is_public: v.optional(v.boolean(), false),
	refund_deadline_days: v.nullable(
		v.pipe(v.number(), v.minValue(0, 'Refund deadline cannot be negative'))
	),
	announce_discord: v.optional(v.boolean(), false),
	announce_email: v.optional(v.boolean(), false)
});

// ============================================================================
// Create Schema (full validation with cross-field checks)
// ============================================================================

export const CreateWorkshopClientSchema = v.pipe(
	BaseWorkshopClientSchema,
	v.forward(
		v.partialCheck(
			[['workshop_date'], ['workshop_end_date']],
			({ workshop_date, workshop_end_date }) => {
				return dayjs(workshop_end_date).isAfter(dayjs(workshop_date));
			},
			'End time cannot be before start time'
		),
		['workshop_end_date']
	)
);

// ============================================================================
// Update Schema (partial - all fields optional)
// ============================================================================

export const UpdateWorkshopClientSchema = v.partial(BaseWorkshopClientSchema);

// ============================================================================
// Remote Schemas (for server-side with string dates for serialization)
// ============================================================================

/**
 * Remote schema for create - dates as ISO strings for serialization.
 * Remote Functions serialize data, so we can't pass Date objects directly.
 */
export const CreateWorkshopRemoteSchema = v.object({
	title: v.pipe(v.string(), v.minLength(1, 'Title is required'), v.maxLength(255)),
	description: v.optional(v.string(), ''),
	location: v.pipe(v.string(), v.minLength(1, 'Location is required')),
	workshop_date: v.pipe(v.string(), v.nonEmpty('Workshop date is required')),
	workshop_end_date: v.pipe(v.string(), v.nonEmpty('Workshop end date is required')),
	max_capacity: v.pipe(v.number(), v.minValue(1, 'Capacity must be at least 1')),
	price_member: v.pipe(v.number(), v.minValue(0, 'Price cannot be negative')),
	price_non_member: v.optional(v.pipe(v.number(), v.minValue(0, 'Price cannot be negative'))),
	is_public: v.optional(v.boolean(), false),
	refund_deadline_days: v.nullable(
		v.pipe(v.number(), v.minValue(0, 'Refund deadline cannot be negative'))
	),
	announce_discord: v.optional(v.boolean(), false),
	announce_email: v.optional(v.boolean(), false)
});

/**
 * Remote schema for update - all fields optional, dates as strings.
 */
export const UpdateWorkshopRemoteSchema = v.partial(CreateWorkshopRemoteSchema);

// ============================================================================
// Type Exports
// ============================================================================

export type CreateWorkshopClientInput = v.InferInput<typeof CreateWorkshopClientSchema>;
export type CreateWorkshopClientOutput = v.InferOutput<typeof CreateWorkshopClientSchema>;
export type UpdateWorkshopClientInput = v.InferInput<typeof UpdateWorkshopClientSchema>;
export type UpdateWorkshopClientOutput = v.InferOutput<typeof UpdateWorkshopClientSchema>;

export type CreateWorkshopRemoteInput = v.InferInput<typeof CreateWorkshopRemoteSchema>;
export type UpdateWorkshopRemoteInput = v.InferInput<typeof UpdateWorkshopRemoteSchema>;
```

---

## Step 2: Create Workshop Remote Functions

Since `workshop-form.svelte` is in `src/lib/components/`, we need to place the remote file somewhere accessible. Two options:

### Option A: Co-located with component (Recommended)
Create `src/lib/components/workshop-form.remote.ts`

### Option B: Route-specific remotes
Keep remote functions in each route's `data.remote.ts`

**We recommend Option A** since the form is shared and the logic is the same.

**File**: `src/lib/components/workshop-form.remote.ts`

```typescript
import { command, getRequestEvent } from '$app/server';
import { redirect } from '@sveltejs/kit';
import * as Sentry from '@sentry/sveltekit';
import dayjs from 'dayjs';
import Dinero from 'dinero.js';
import * as v from 'valibot';
import { authorize } from '$lib/server/auth';
import { WORKSHOP_ROLES } from '$lib/server/roles';
import { createWorkshopService } from '$lib/server/services/workshops';
import {
	CreateWorkshopRemoteSchema,
	UpdateWorkshopRemoteSchema
} from '$lib/schemas/workshop';

// ============================================================================
// Helper: Transform form data to database format
// ============================================================================

interface TransformOptions {
	checkPricingPermission?: boolean;
	currentPriceMember?: number;
}

function transformWorkshopData(
	data: v.InferOutput<typeof CreateWorkshopRemoteSchema>,
	options: TransformOptions = {}
) {
	const startDateTime = dayjs(data.workshop_date).toISOString();
	const endDateTime = dayjs(data.workshop_end_date).toISOString();

	// Convert euro prices to cents
	const memberPriceCents = Dinero({
		amount: Math.round((data.price_member ?? 0) * 100),
		currency: 'EUR'
	}).getAmount();

	const nonMemberPriceCents =
		data.is_public && data.price_non_member
			? Dinero({
					amount: Math.round(data.price_non_member * 100),
					currency: 'EUR'
				}).getAmount()
			: options.currentPriceMember ?? memberPriceCents;

	return {
		title: data.title,
		description: data.description,
		location: data.location,
		start_date: startDateTime,
		end_date: endDateTime,
		max_capacity: data.max_capacity,
		price_member: memberPriceCents,
		price_non_member: nonMemberPriceCents,
		is_public: data.is_public ?? false,
		refund_days: data.refund_deadline_days,
		announce_discord: data.announce_discord ?? false,
		announce_email: data.announce_email ?? false
	};
}

// ============================================================================
// Create Workshop Command
// ============================================================================

export const createWorkshop = command(CreateWorkshopRemoteSchema, async (data) => {
	const event = getRequestEvent();
	const session = await authorize(event.locals, WORKSHOP_ROLES);

	try {
		const workshopData = transformWorkshopData(data);
		const workshopService = createWorkshopService(event.platform!, session);
		const workshop = await workshopService.create(workshopData);

		return {
			success: `Workshop "${workshop.title}" created successfully!`,
			workshopId: workshop.id
		};
	} catch (error) {
		Sentry.captureException(error);
		console.error('Create workshop error:', error);
		throw new Error('Failed to create workshop. Please try again.');
	}
});

// ============================================================================
// Update Workshop Command
// ============================================================================

/**
 * Extended schema for update that includes workshopId
 */
const UpdateWorkshopWithIdSchema = v.object({
	...UpdateWorkshopRemoteSchema.entries,
	workshopId: v.pipe(v.string(), v.uuid())
});

export const updateWorkshop = command(UpdateWorkshopWithIdSchema, async (data) => {
	const event = getRequestEvent();
	const session = await authorize(event.locals, WORKSHOP_ROLES);

	const { workshopId, ...formData } = data;

	try {
		const workshopService = createWorkshopService(event.platform!, session);

		// Fetch current workshop to validate edit permissions
		const currentWorkshop = await workshopService.findById(workshopId);

		// Check if workshop can be edited
		const workshopEditable = await workshopService.canEdit(workshopId);
		if (!workshopEditable) {
			throw new Error('Only planned workshops can be edited');
		}

		// Check if pricing changes are allowed
		const pricingEditable = await workshopService.canEditPricing(workshopId);
		if (
			!pricingEditable &&
			(formData.price_member !== undefined || formData.price_non_member !== undefined)
		) {
			throw new Error('Cannot change pricing when there are already registered attendees');
		}

		// Build update data
		const updateData: Record<string, unknown> = {};

		if (formData.title !== undefined) updateData.title = formData.title;
		if (formData.description !== undefined) updateData.description = formData.description;
		if (formData.location !== undefined) updateData.location = formData.location;
		if (formData.max_capacity !== undefined) updateData.max_capacity = formData.max_capacity;
		if (formData.is_public !== undefined) updateData.is_public = formData.is_public;
		if (formData.refund_deadline_days !== undefined) {
			updateData.refund_days = formData.refund_deadline_days;
		}

		// Handle dates
		if (formData.workshop_date !== undefined) {
			updateData.start_date = dayjs(formData.workshop_date).toISOString();
		}
		if (formData.workshop_end_date !== undefined) {
			const endDate = dayjs(formData.workshop_end_date);
			const baseDate = formData.workshop_date
				? dayjs(formData.workshop_date)
				: dayjs(currentWorkshop.start_date);
			updateData.end_date = baseDate
				.set('hour', endDate.hour())
				.set('minute', endDate.minute())
				.toISOString();
		}

		// Handle pricing (only if editable)
		if (pricingEditable) {
			if (typeof formData.price_member === 'number') {
				updateData.price_member = Dinero({
					amount: Math.round(formData.price_member * 100),
					currency: 'EUR'
				}).getAmount();
			}

			if (typeof formData.price_non_member === 'number') {
				updateData.price_non_member =
					formData.is_public && formData.price_non_member
						? Dinero({
								amount: Math.round(formData.price_non_member * 100),
								currency: 'EUR'
							}).getAmount()
						: (updateData.price_member as number) ?? currentWorkshop.price_member;
			}
		}

		const workshop = await workshopService.update(workshopId, updateData);

		return {
			success: `Workshop "${workshop.title}" updated successfully!`
		};
	} catch (error) {
		Sentry.captureException(error);
		console.error('Update workshop error:', error);
		if (error instanceof Error) {
			throw error;
		}
		throw new Error('Failed to update workshop. Please try again.');
	}
});
```

---

## Step 3: Migrate workshop-form.svelte

**File**: `src/lib/components/workshop-form.svelte`

```svelte
<script lang="ts">
	import { createWorkshop, updateWorkshop } from './workshop-form.remote';
	import {
		CreateWorkshopClientSchema,
		UpdateWorkshopClientSchema
	} from '$lib/schemas/workshop';
	import * as Field from '$lib/components/ui/field';
	import { Button } from '$lib/components/ui/button';
	import { Input } from '$lib/components/ui/input';
	import { Textarea } from '$lib/components/ui/textarea';
	import { Switch } from '$lib/components/ui/switch';
	import { Alert, AlertDescription } from '$lib/components/ui/alert';
	import Calendar25 from '$lib/components/calendar-25.svelte';
	import { CheckCircle } from 'lucide-svelte';
	import LoaderCircle from '$lib/components/ui/loader-circle.svelte';
	import {
		type CalendarDate,
		fromDate,
		getLocalTimeZone,
		toCalendarDate,
		toCalendarDateTime
	} from '@internationalized/date';
	import utc from 'dayjs/plugin/utc';
	import timezone from 'dayjs/plugin/timezone';
	import dayjs from 'dayjs';

	dayjs.extend(utc);
	dayjs.extend(timezone);
	dayjs.tz.setDefault(dayjs.tz.guess());

	interface Props {
		mode: 'create' | 'edit';
		workshopId?: string; // Required for edit mode
		initialData?: Partial<{
			title: string;
			description: string;
			location: string;
			workshop_date: Date;
			workshop_end_date: Date;
			max_capacity: number;
			price_member: number;
			price_non_member: number;
			is_public: boolean;
			refund_deadline_days: number | null;
			announce_discord: boolean;
			announce_email: boolean;
		}>;
		onSuccess?: (result: { success: string; workshopId?: string }) => void;
		priceEditingDisabled?: boolean;
		workshopStatus?: string | null;
		workshopEditable?: boolean;
	}

	let {
		mode,
		workshopId,
		initialData,
		onSuccess,
		priceEditingDisabled = false,
		workshopStatus,
		workshopEditable
	}: Props = $props();

	// Select the appropriate command based on mode
	const formCommand = mode === 'create' ? createWorkshop : updateWorkshop;
	const schema = mode === 'create' ? CreateWorkshopClientSchema : UpdateWorkshopClientSchema;

	// Local state for form values (needed for controlled inputs)
	let title = $state(initialData?.title ?? '');
	let description = $state(initialData?.description ?? '');
	let location = $state(initialData?.location ?? '');
	let workshopDate = $state<Date | undefined>(initialData?.workshop_date);
	let workshopEndDate = $state<Date | undefined>(initialData?.workshop_end_date);
	let maxCapacity = $state(initialData?.max_capacity ?? 1);
	let priceMember = $state(initialData?.price_member ?? 0);
	let priceNonMember = $state(initialData?.price_non_member ?? 0);
	let isPublic = $state(initialData?.is_public ?? false);
	let refundDeadlineDays = $state<number | null>(initialData?.refund_deadline_days ?? null);
	let announceDiscord = $state(initialData?.announce_discord ?? false);
	let announceEmail = $state(initialData?.announce_email ?? false);

	// Message state
	let successMessage = $state<string | null>(null);
	let errorMessage = $state<string | null>(null);

	// Derived date values for Calendar25
	const workshopDateValue = $derived.by(() => {
		if (!workshopDate || !dayjs(workshopDate).isValid()) {
			return undefined;
		}
		return toCalendarDate(fromDate(workshopDate, getLocalTimeZone()));
	});

	const startTime = $derived.by(() => {
		if (!workshopDate || !dayjs(workshopDate).isValid()) return '';
		return dayjs(workshopDate).format('HH:mm');
	});

	const endTime = $derived.by(() => {
		if (!workshopEndDate || !dayjs(workshopEndDate).isValid()) return '';
		return dayjs(workshopEndDate).format('HH:mm');
	});

	// Date update helper
	function updateWorkshopDates(
		date?: CalendarDate | string,
		op: 'start' | 'end' | 'date' = 'date'
	) {
		if (!date) return;

		if (typeof date === 'string' && op === 'start') {
			const [hour, minute] = date.split(':').map(Number);
			const currentDate = dayjs(workshopDate);
			const baseDate = currentDate.isValid() ? currentDate : dayjs();
			workshopDate = baseDate.hour(hour).minute(minute).toDate();
			return;
		}

		if (typeof date === 'string' && op === 'end') {
			const [hour, minute] = date.split(':').map(Number);
			let baseDate = dayjs(workshopEndDate);
			if (!baseDate.isValid()) {
				baseDate = dayjs(workshopDate);
			}
			if (!baseDate.isValid()) {
				baseDate = dayjs();
			}
			workshopEndDate = baseDate.hour(hour).minute(minute).toDate();
			return;
		}

		// Handle date change (CalendarDate) - preserve existing times or use defaults
		if (typeof date !== 'string') {
			const startDateDayjs = dayjs(workshopDate);
			const startTimeVal = startDateDayjs.isValid()
				? { hour: startDateDayjs.hour(), minute: startDateDayjs.minute() }
				: { hour: 10, minute: 0 };

			const endDateDayjs = dayjs(workshopEndDate);
			const endTimeVal = endDateDayjs.isValid()
				? { hour: endDateDayjs.hour(), minute: endDateDayjs.minute() }
				: { hour: 12, minute: 0 };

			workshopDate = toCalendarDateTime(date).set(startTimeVal).toDate(getLocalTimeZone());
			workshopEndDate = toCalendarDateTime(date).set(endTimeVal).toDate(getLocalTimeZone());
		}
	}

	// Edit permissions
	const isWorkshopEditable = $derived.by(() => {
		if (mode === 'create') return true;
		if (workshopStatus === 'published') return false;
		if (workshopEditable !== undefined) return workshopEditable;
		return workshopStatus === 'planned';
	});

	const canEditPricing = $derived.by(() => {
		if (mode === 'create') return true;
		if (workshopStatus === 'planned') return true;
		return !priceEditingDisabled;
	});

	// Form submission
	async function handleSubmit(event: SubmitEvent) {
		event.preventDefault();
		successMessage = null;
		errorMessage = null;

		// Build form data with ISO string dates for serialization
		const formData: Record<string, unknown> = {
			title,
			description,
			location,
			workshop_date: workshopDate ? dayjs(workshopDate).toISOString() : '',
			workshop_end_date: workshopEndDate ? dayjs(workshopEndDate).toISOString() : '',
			max_capacity: maxCapacity,
			price_member: priceMember,
			price_non_member: isPublic ? priceNonMember : undefined,
			is_public: isPublic,
			refund_deadline_days: refundDeadlineDays,
			announce_discord: announceDiscord,
			announce_email: announceEmail
		};

		// Add workshopId for updates
		if (mode === 'edit' && workshopId) {
			formData.workshopId = workshopId;
		}

		try {
			const result = await formCommand.run(formData);

			if (result.success) {
				successMessage = result.success;
				window?.scrollTo({ top: 0, behavior: 'smooth' });

				if (onSuccess) {
					onSuccess(result);
				}
			}
		} catch (error) {
			errorMessage = error instanceof Error ? error.message : 'An error occurred';
			window?.scrollTo({ top: 0, behavior: 'smooth' });
		}
	}
</script>

<div class="space-y-8">
	{#if successMessage}
		<Alert variant="default" class="border-green-200 bg-green-50">
			<CheckCircle class="h-4 w-4 text-green-600" />
			<AlertDescription class="text-green-800">{successMessage}</AlertDescription>
		</Alert>
	{/if}

	{#if errorMessage}
		<Alert variant="destructive">
			<AlertDescription>{errorMessage}</AlertDescription>
		</Alert>
	{/if}

	{#if !isWorkshopEditable}
		<Alert variant="default" class="border-yellow-200 bg-yellow-50">
			<AlertDescription class="text-yellow-800">
				{#if workshopStatus === 'published'}
					This workshop cannot be edited because it has been published.
				{:else if workshopStatus === 'finished'}
					This workshop cannot be edited because it has been finished.
				{:else if workshopStatus === 'cancelled'}
					This workshop cannot be edited because it has been cancelled.
				{:else}
					This workshop cannot be edited because it has been published, finished, or cancelled.
				{/if}
			</AlertDescription>
		</Alert>
	{/if}

	<form
		onsubmit={handleSubmit}
		class="space-y-8 rounded-lg border bg-white p-6 shadow-sm"
	>
		<!-- Basic Information Section -->
		<div class="space-y-6">
			<h2 class="border-b pb-2 text-xl font-semibold text-gray-900">
				Basic Information
			</h2>

			<div class="grid grid-cols-1 gap-6 md:grid-cols-2">
				<Field.Field>
					<Field.Label for="title">Title</Field.Label>
					<Input
						id="title"
						name="title"
						bind:value={title}
						placeholder="Enter workshop title"
						disabled={!isWorkshopEditable}
					/>
				</Field.Field>

				<Field.Field>
					<Field.Label for="location">Location</Field.Label>
					<Input
						id="location"
						name="location"
						bind:value={location}
						placeholder="Enter workshop location"
						disabled={!isWorkshopEditable}
					/>
				</Field.Field>
			</div>

			<Field.Field>
				<Field.Label for="description">Description</Field.Label>
				<Textarea
					id="description"
					name="description"
					bind:value={description}
					placeholder="Enter workshop description"
					rows={4}
					disabled={!isWorkshopEditable}
				/>
			</Field.Field>
		</div>

		<!-- Date & Time Section -->
		<div class="space-y-6">
			<h2 class="border-b pb-2 text-xl font-semibold text-gray-900">
				Date & Time
			</h2>

			<Field.Field>
				<Field.Label>Workshop Date & Time</Field.Label>
				<div class="rounded-lg bg-gray-50 p-4">
					<Calendar25
						id="workshop"
						date={workshopDateValue}
						{startTime}
						{endTime}
						onDateChange={(d) => updateWorkshopDates(d, 'date')}
						onStartTimeChange={(d) => updateWorkshopDates(d, 'start')}
						onEndTimeChange={(d) => updateWorkshopDates(d, 'end')}
						disabled={!isWorkshopEditable}
					/>
				</div>
			</Field.Field>
		</div>

		<!-- Workshop Details Section -->
		<div class="space-y-6">
			<h2 class="border-b pb-2 text-xl font-semibold text-gray-900">
				Workshop Details
			</h2>

			<div class="grid grid-cols-1 gap-6 md:grid-cols-2">
				<Field.Field>
					<Field.Label for="max_capacity">Maximum Capacity</Field.Label>
					<Input
						id="max_capacity"
						name="max_capacity"
						type="number"
						min="1"
						bind:value={maxCapacity}
						placeholder="Enter maximum capacity"
						disabled={!isWorkshopEditable}
					/>
				</Field.Field>

				<Field.Field>
					<Field.Label for="refund_deadline_days">Refund Deadline (days)</Field.Label>
					<Input
						id="refund_deadline_days"
						name="refund_deadline_days"
						type="number"
						min="0"
						bind:value={refundDeadlineDays}
						placeholder="3"
						disabled={!isWorkshopEditable}
					/>
					<p class="mt-1 text-sm text-muted-foreground">
						Days before workshop when refunds are no longer available
					</p>
				</Field.Field>
			</div>
		</div>

		<!-- Communication Settings Section (Create mode only) -->
		{#if mode === 'create'}
			<div class="space-y-6">
				<h2 class="border-b pb-2 text-xl font-semibold text-gray-900">
					Communication Settings
				</h2>

				<div class="rounded-lg border border-blue-200 bg-blue-50 p-4">
					<p class="mb-4 text-sm text-blue-700">
						All workshop status changes will be announced through selected channels
					</p>

					<div class="space-y-4">
						<div class="flex items-center space-x-3">
							<Switch
								id="announce_discord"
								bind:checked={announceDiscord}
							/>
							<div>
								<label for="announce_discord" class="text-base font-medium">
									Announce in Discord
								</label>
								<p class="text-sm text-blue-700">
									Send workshop announcements to the Discord server
								</p>
							</div>
						</div>

						<div class="flex items-center space-x-3">
							<Switch
								id="announce_email"
								bind:checked={announceEmail}
							/>
							<div>
								<label for="announce_email" class="text-base font-medium">
									Announce via Email
								</label>
								<p class="text-sm text-blue-700">
									Send workshop announcements via email to all active members
								</p>
							</div>
						</div>
					</div>
				</div>
			</div>
		{/if}

		<!-- Pricing & Access Section -->
		<div class="space-y-6">
			<h2 class="border-b pb-2 text-xl font-semibold text-gray-900">
				Pricing & Access
			</h2>

			{#if !canEditPricing}
				<Alert variant="default" class="border-orange-200 bg-orange-50">
					<AlertDescription class="text-orange-800">
						Pricing cannot be changed because there are already registered attendees.
					</AlertDescription>
				</Alert>
			{/if}

			<div class="flex items-center space-x-3 rounded-lg border border-blue-200 bg-blue-50 p-4">
				<Switch
					id="is_public"
					bind:checked={isPublic}
					disabled={!isWorkshopEditable}
				/>
				<div>
					<label for="is_public" class="text-base font-medium">
						Public Workshop
					</label>
					<p class="mt-1 text-sm text-blue-700">
						Enable this to allow non-members to register for the workshop
					</p>
				</div>
			</div>

			<div class="grid grid-cols-1 gap-6 md:grid-cols-2">
				<Field.Field>
					<Field.Label for="price_member">Member Price</Field.Label>
					<div class="relative">
						<span class="absolute left-3 top-1/2 -translate-y-1/2 text-sm text-muted-foreground">
							€
						</span>
						<Input
							id="price_member"
							name="price_member"
							type="number"
							min="0"
							step="0.01"
							class="pl-8"
							bind:value={priceMember}
							placeholder="10.00"
							disabled={!canEditPricing}
						/>
					</div>
				</Field.Field>

				{#if isPublic}
					<Field.Field>
						<Field.Label for="price_non_member">Non-Member Price</Field.Label>
						<div class="relative">
							<span class="absolute left-3 top-1/2 -translate-y-1/2 text-sm text-muted-foreground">
								€
							</span>
							<Input
								id="price_non_member"
								name="price_non_member"
								type="number"
								min="0"
								step="0.01"
								class="pl-8"
								bind:value={priceNonMember}
								placeholder="20.00"
								disabled={!canEditPricing}
							/>
						</div>
					</Field.Field>
				{:else}
					<div class="flex h-20 items-center justify-center rounded-lg border border-dashed border-gray-300 bg-gray-50 text-sm text-muted-foreground">
						<div class="text-center">
							<p class="font-medium">Non-Member Pricing</p>
							<p class="text-xs">Available for public workshops only</p>
						</div>
					</div>
				{/if}
			</div>
		</div>

		<!-- Submit Section -->
		<div class="border-t pt-6">
			<Button
				type="submit"
				disabled={formCommand.pending || !isWorkshopEditable}
				class="h-12 w-full text-lg"
			>
				{#if formCommand.pending}
					<LoaderCircle class="mr-2 h-5 w-5" />
					{mode === 'create' ? 'Creating' : 'Updating'} Workshop...
				{:else}
					{mode === 'create' ? 'Create' : 'Update'} Workshop
				{/if}
			</Button>
		</div>
	</form>
</div>
```

---

## Step 4: Update Parent Pages

### Create Page (`src/routes/dashboard/workshops/create/+page.svelte`)

```svelte
<script lang="ts">
	import WorkshopForm from '$lib/components/workshop-form.svelte';
	import { Button } from '$lib/components/ui/button';
	import { Alert, AlertDescription } from '$lib/components/ui/alert';
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { Sparkles } from 'lucide-svelte';

	const { data } = $props();

	function handleSuccess() {
		setTimeout(() => goto(resolve('/dashboard/workshops')), 2000);
	}
</script>

<div class="mx-auto max-w-4xl space-y-8 p-6">
	<div class="flex items-center justify-between">
		<h1 class="text-3xl font-bold">Create Workshop</h1>
		<Button variant="outline" href="/dashboard/workshops">Back to Workshops</Button>
	</div>

	{#if data.isGenerated}
		<Alert variant="default" class="border-blue-200 bg-blue-50">
			<Sparkles class="h-4 w-4 text-blue-600" />
			<AlertDescription class="text-blue-800">
				Workshop details have been generated from your description. Review and modify as needed
				before creating.
			</AlertDescription>
		</Alert>
	{/if}

	<WorkshopForm
		mode="create"
		initialData={data.initialData}
		onSuccess={handleSuccess}
	/>
</div>
```

### Create Page Server (`src/routes/dashboard/workshops/create/+page.server.ts`)

```typescript
import { authorize } from '$lib/server/auth';
import { WORKSHOP_ROLES } from '$lib/server/roles';
import { coerceToCreateWorkshopSchema } from '$lib/server/workshop-generator';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ locals, url }) => {
	await authorize(locals, WORKSHOP_ROLES);

	// Check if this is a generated workshop (from quick create)
	const generatedParam = url.searchParams.get('generated');
	let initialData = null;

	if (generatedParam && generatedParam !== 'true') {
		try {
			const parsed = coerceToCreateWorkshopSchema(
				JSON.parse(decodeURIComponent(generatedParam))
			)?.output;
			if (parsed) {
				initialData = {
					title: parsed.title,
					description: parsed.description,
					location: parsed.location,
					workshop_date: parsed.workshop_date,
					workshop_end_date: parsed.workshop_end_date,
					max_capacity: parsed.max_capacity,
					price_member: parsed.price_member,
					price_non_member: parsed.price_non_member,
					is_public: parsed.is_public,
					refund_deadline_days: parsed.refund_deadline_days,
					announce_discord: parsed.announce_discord,
					announce_email: parsed.announce_email
				};
			}
		} catch (error) {
			console.error('Failed to parse generated data:', error);
		}
	}

	return {
		initialData,
		isGenerated: !!initialData
	};
};

// No actions needed - Remote Functions handle submission
```

### Edit Page (`src/routes/dashboard/workshops/[id]/edit/+page.svelte`)

```svelte
<script lang="ts">
	import WorkshopForm from '$lib/components/workshop-form.svelte';
	import { Button } from '$lib/components/ui/button';
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';

	const { data } = $props();

	function handleSuccess() {
		setTimeout(() => goto(resolve('/dashboard/workshops')), 2000);
	}
</script>

<div class="mx-auto max-w-4xl space-y-8 p-6">
	<div class="flex items-center justify-between">
		<h1 class="text-3xl font-bold">Edit Workshop</h1>
		<Button variant="outline" href="/dashboard/workshops">Back to Workshops</Button>
	</div>

	<WorkshopForm
		mode="edit"
		workshopId={data.workshop.id}
		initialData={data.initialData}
		onSuccess={handleSuccess}
		priceEditingDisabled={data.priceEditingDisabled}
		workshopStatus={data.workshop.status}
		workshopEditable={data.workshopEditable}
	/>
</div>
```

### Edit Page Server (`src/routes/dashboard/workshops/[id]/edit/+page.server.ts`)

```typescript
import { authorize } from '$lib/server/auth';
import { WORKSHOP_ROLES } from '$lib/server/roles';
import { createWorkshopService } from '$lib/server/services/workshops';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async ({ locals, params, platform }) => {
	const session = await authorize(locals, WORKSHOP_ROLES);

	const workshopService = createWorkshopService(platform!, session);

	// Fetch workshop data
	const workshop = await workshopService.findById(params.id);

	// Check if workshop can be edited
	const workshopEditable = await workshopService.canEdit(params.id);

	// Check if pricing can be edited
	const pricingEditable = await workshopService.canEditPricing(params.id);

	// Transform workshop data to form format
	const initialData = {
		title: workshop.title,
		description: workshop.description || '',
		location: workshop.location,
		workshop_date: new Date(workshop.start_date),
		workshop_end_date: new Date(workshop.end_date),
		max_capacity: workshop.max_capacity,
		price_member: workshop.price_member / 100, // Convert from cents to euros
		price_non_member: workshop.price_non_member ? workshop.price_non_member / 100 : undefined,
		is_public: workshop.is_public || false,
		refund_deadline_days: workshop.refund_days || null
	};

	return {
		workshop,
		initialData,
		workshopEditable,
		priceEditingDisabled: !pricingEditable
	};
};

// No actions needed - Remote Functions handle submission
```

---

## Step 5: Update Service Schemas (Optional)

The service layer schemas in `src/lib/server/services/workshops/workshop.service.ts` can remain as-is since they're used for server-side validation. However, you may want to re-export them from the client schema file for consistency:

```typescript
// In src/lib/schemas/workshop.ts, add at the end:

// Re-export server schemas for backward compatibility
export {
	BaseWorkshopSchema,
	CreateWorkshopSchema,
	UpdateWorkshopSchema
} from '$lib/server/services/workshops/workshop.service';
```

---

## Testing Checklist

### Create Workshop
- [ ] Fill all required fields
- [ ] Date picker works correctly
- [ ] Time picker preserves times when changing dates
- [ ] Toggle is_public shows/hides non-member price
- [ ] Communication settings (Discord/Email) toggle
- [ ] Form submission creates workshop
- [ ] Success message displays
- [ ] Redirect after success

### Edit Workshop
- [ ] Form loads with existing data
- [ ] Date/time display correctly
- [ ] Planned workshop: all fields editable
- [ ] Published workshop: fields disabled, warning shown
- [ ] Pricing disabled when registrations exist
- [ ] Form submission updates workshop
- [ ] Success message displays

### Validation
- [ ] Title required
- [ ] Location required
- [ ] Workshop date cannot be today
- [ ] End time must be after start time
- [ ] Capacity minimum 1
- [ ] Prices non-negative

### Edge Cases
- [ ] Generated workshop data from URL params
- [ ] Price conversion (euros to cents)
- [ ] Date timezone handling

---

## Migration Summary

| Before | After |
|--------|-------|
| `superForm` with `valibotClient` | `command` from Remote Functions |
| `$formData` store | Local `$state` variables |
| `use:enhance` | `onsubmit` handler with `command.run()` |
| `$submitting` store | `command.pending` |
| `$message` store | Local `successMessage`/`errorMessage` state |
| `data.form` from loader | `initialData` prop |
| Actions in `+page.server.ts` | Remote functions in `.remote.ts` |

---

## Notes

1. **Schema Splitting Pattern**: Client schemas use `Date` objects; remote schemas use ISO strings for serialization.

2. **Progressive Enhancement**: Remote Functions support progressive enhancement. For full PE, add hidden inputs with serialized values.

3. **Validation**: Client-side validation happens via the schema. Server-side validation happens in the remote function.

4. **Error Handling**: Errors thrown in remote functions are caught in the `handleSubmit` try/catch.

5. **Pending State**: Use `command.pending` to show loading indicators.
