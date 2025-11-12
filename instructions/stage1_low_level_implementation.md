# Stage 1: Low-Level Technical Implementation ✅ DONE

## Technical Implementation Plan

### 1. Database Schema (`supabase/migrations/`)

**Migration file**: `pnpm supabase migrations new create_club_activities`

```sql
-- Create enums
CREATE TYPE club_activity_status AS ENUM ('planned', 'published', 'finished', 'cancelled');

-- Create club_activities table
CREATE TABLE club_activities
(
    id               UUID PRIMARY KEY     DEFAULT gen_random_uuid(),
    title            TEXT        NOT NULL,
    description      TEXT,
    location         TEXT        NOT NULL,
    start_date       TIMESTAMPTZ NOT NULL,
    end_date         TIMESTAMPTZ NOT NULL,
    max_capacity     INTEGER     NOT NULL CHECK (max_capacity > 0),
    price_member     FLOAT       NOT NULL CHECK (price_member >= 0),          -- cents
    price_non_member FLOAT       NOT NULL CHECK (price_non_member >= 0),      -- cents
    is_public        BOOLEAN              DEFAULT false,
    refund_days      INTEGER              DEFAULT 3 CHECK (refund_days >= 0), -- NULL means no refunds
    status           club_activity_status DEFAULT 'planned',
    created_at       TIMESTAMPTZ          DEFAULT now(),
    updated_at       TIMESTAMPTZ          DEFAULT now(),
    created_by       UUID REFERENCES auth.users (id)
);

-- RLS policies
ALTER TABLE club_activities
    ENABLE ROW LEVEL SECURITY;

-- Policy for workshop coordinators
CREATE POLICY "Workshop coordinators can manage activities" ON club_activities
    FOR ALL USING (
    (
        (SELECT has_any_role(
                        (SELECT auth.uid()),
                        ARRAY ['workshop_coordinator', 'president', 'admin']::role_type[]
                )))
    );

-- Triggers for updated_at
CREATE OR REPLACE FUNCTION update_updated_at_column()
    RETURNS TRIGGER AS
$$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER update_club_activities_updated_at
    BEFORE UPDATE
    ON club_activities
    FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();
```

### 2. TypeScript Types (`src/lib/types/`)

Generate with pnpm database:types after migrations are applied.

### 3. Kysely Models (`src/lib/server/`)

**File**: `src/lib/server/workshops.ts`

```typescript
import { executeWithRLS } from './kysely';
import type { ClubActivityInsert, ClubActivityUpdate } from '../types/workshops';

export async function createWorkshop(
	data: ClubActivityInsert,
	userId: string,
	platform: App.Platform
): Promise<ClubActivity> {
	const kysely = getKyselyClient(platform.env.HYPERDRIVE);
	const result = await executeWithRLS(kysely, { claims: { sub: userId } }, async (trx) => {
		return await trx
			.insertInto('club_activities')
			.values({ ...data, created_by: userId })
			.returning('*')
			.executeTakeFirstOrThrow();
	});
	return result;
}

export async function updateWorkshop(
	id: string,
	data: ClubActivityUpdate,
	userId: string,
	platform: App.Platform
): Promise<ClubActivity> {
	const kysely = getKyselyClient(platform.env.HYPERDRIVE);
	const result = await executeWithRLS(kysely, { claims: { sub: userId } }, async (trx) => {
		return await trx
			.updateTable('club_activities')
			.set(data)
			.where('id', '=', id)
			.returning('*')
			.executeTakeFirstOrThrow();
	});
	return result;
}

export async function deleteWorkshop(
	id: string,
	userId: string,
	platform: App.Platform
): Promise<void> {
	const kysely = getKyselyClient(platform.env.HYPERDRIVE);
	await executeWithRLS(kysely, { claims: { sub: userId } }, async (trx) => {
		await trx.deleteFrom('club_activities').where('id', '=', id).execute();
	});
}

export async function publishWorkshop(
	id: string,
	userId: string,
	platform: App.Platform
): Promise<ClubActivity> {
	const kysely = getKyselyClient(platform.env.HYPERDRIVE);
	const result = await executeWithRLS(kysely, { claims: { sub: userId } }, async (trx) => {
		return await trx
			.updateTable('club_activities')
			.set({ status: 'published' })
			.where('id', '=', id)
			.where('status', '=', 'planned')
			.returning('*')
			.executeTakeFirstOrThrow();
	});
	return result;
}

export async function cancelWorkshop(
	id: string,
	userId: string,
	platform: App.Platform
): Promise<ClubActivity> {
	const kysely = getKyselyClient(platform.env.HYPERDRIVE);
	const result = await executeWithRLS(kysely, { claims: { sub: userId } }, async (trx) => {
		return await trx
			.updateTable('club_activities')
			.set({ status: 'cancelled' })
			.where('id', '=', id)
			.where('status', 'in', ['planned', 'published'])
			.returning('*')
			.executeTakeFirstOrThrow();
	});
	return result;
}
```

### 4. Validation Schemas (`src/lib/schemas/`)

**File**: `src/lib/schemas/workshops.ts`

```typescript
import * as v from 'valibot';

export const CreateWorkshopSchema = v.object({
	title: v.pipe(v.string(), v.minLength(1, 'Title is required'), v.maxLength(255)),
	description: v.string(),
	location: v.string(),
	start_date: v.pipe(v.string(), v.isoDateTime()),
	end_date: v.pipe(v.string(), v.isoDateTime()),
	max_capacity: v.pipe(v.number(), v.minValue(1, 'Capacity must be at least 1')),
	price_member: v.pipe(v.number(), v.minValue(0, 'Price cannot be negative')),
	price_non_member: v.pipe(v.number(), v.minValue(0, 'Price cannot be negative')),
	is_public: v.optional(v.boolean(), false),
	refund_days: v.nullable(v.pipe(v.number(), v.minValue(0, 'Refund days cannot be negative')))
});

export const UpdateWorkshopSchema = v.partial(CreateWorkshopSchema);
```

### 5. Authorization Utility (`src/lib/server/`)

**File**: `src/lib/server/auth.ts` (add to existing file)

```typescript
import { getRolesFromSession } from './roles';
import { invariant } from './utils';

export async function authorize(locals: App.Locals, allowedRoles: string[]) {
	const { session } = await locals.safeGetSession();
	invariant(session === null, 'Unauthorized');

	const roles = getRolesFromSession(session!);
	const hasPermission = roles.intersection(new Set(allowedRoles)).size > 0;
	invariant(!hasPermission, 'Unauthorized', 403);

	return session!;
}
```

### 6. API Endpoints (`src/routes/api/workshops/`)

**File**: `src/routes/api/workshops/+server.ts`

```typescript
import { json } from '@sveltejs/kit';
import { authorize } from '$lib/server/auth';
import { createWorkshop } from '$lib/server/workshops';
import { CreateWorkshopSchema } from '$lib/schemas/workshops';
import { safeParse } from 'valibot';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = async ({ request, locals, platform }) => {
	try {
		const session = await authorize(locals, ['admin', 'president', 'workshop_coordinator']);

		const body = await request.json();
		const result = safeParse(CreateWorkshopSchema, body);

		if (!result.success) {
			return json(
				{ success: false, error: 'Invalid data', issues: result.issues },
				{ status: 400 }
			);
		}

		const workshop = await createWorkshop(result.output, session.user.id, platform);

		return json({ success: true, workshop });
	} catch (error) {
		console.error('Create workshop error:', error);
		return json({ success: false, error: error.message }, { status: 500 });
	}
};
```

**File**: `src/routes/api/workshops/[id]/+server.ts`

```typescript
import { json } from '@sveltejs/kit';
import { authorize } from '$lib/server/auth';
import { updateWorkshop, deleteWorkshop } from '$lib/server/workshops';
import { UpdateWorkshopSchema } from '$lib/schemas/workshops';
import { safeParse } from 'valibot';
import type { RequestHandler } from './$types';

export const PUT: RequestHandler = async ({ request, locals, params, platform }) => {
	try {
		const session = await authorize(locals, ['admin', 'president', 'workshop_coordinator']);

		const body = await request.json();
		const result = safeParse(UpdateWorkshopSchema, body);

		if (!result.success) {
			return json(
				{ success: false, error: 'Invalid data', issues: result.issues },
				{ status: 400 }
			);
		}

		const workshop = await updateWorkshop(params.id!, result.output, session.user.id, platform);

		return json({ success: true, workshop });
	} catch (error) {
		console.error('Update workshop error:', error);
		return json({ success: false, error: error.message }, { status: 500 });
	}
};

export const DELETE: RequestHandler = async ({ locals, params, platform }) => {
	try {
		const session = await authorize(locals, ['admin', 'president', 'workshop_coordinator']);

		await deleteWorkshop(params.id!, session.user.id, platform);

		return json({ success: true });
	} catch (error) {
		console.error('Delete workshop error:', error);
		return json({ success: false, error: error.message }, { status: 500 });
	}
};
```

**File**: `src/routes/api/workshops/[id]/publish/+server.ts`

```typescript
import { json } from '@sveltejs/kit';
import { authorize } from '$lib/server/auth';
import { publishWorkshop } from '$lib/server/workshops';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = async ({ locals, params, platform }) => {
	try {
		const session = await authorize(locals, ['admin', 'president', 'workshop_coordinator']);

		const workshop = await publishWorkshop(params.id!, session.user.id, platform);

		return json({ success: true, workshop });
	} catch (error) {
		console.error('Publish workshop error:', error);
		return json({ success: false, error: error.message }, { status: 500 });
	}
};
```

**File**: `src/routes/api/workshops/[id]/cancel/+server.ts`

```typescript
import { json } from '@sveltejs/kit';
import { authorize } from '$lib/server/auth';
import { cancelWorkshop } from '$lib/server/workshops';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = async ({ locals, params, platform }) => {
	try {
		const session = await authorize(locals, ['admin', 'president', 'workshop_coordinator']);

		const workshop = await cancelWorkshop(params.id!, session.user.id, platform);

		return json({ success: true, workshop });
	} catch (error) {
		console.error('Cancel workshop error:', error);
		return json({ success: false, error: error.message }, { status: 500 });
	}
};
```

### 7. Frontend Routes with Superforms (`src/routes/dashboard/workshops/`)

**File**: `src/routes/dashboard/workshops/create/+page.server.ts`

```typescript
import { superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import { fail } from '@sveltejs/kit';
import { CreateWorkshopSchema } from '$lib/schemas/workshops';
import { createWorkshop } from '$lib/server/workshops';
import { authorize } from '$lib/server/auth';
import { message } from 'sveltekit-superforms';
import type { PageServerLoad, Actions } from './$types';

export const load: PageServerLoad = async ({ locals }) => {
	await authorize(locals, ['admin', 'president', 'workshop_coordinator']);

	return {
		form: await superValidate(valibot(CreateWorkshopSchema))
	};
};

export const actions: Actions = {
	default: async ({ request, locals, platform }) => {
		const session = await authorize(locals, ['admin', 'president', 'workshop_coordinator']);

		const form = await superValidate(request, valibot(CreateWorkshopSchema));

		if (!form.valid) {
			return fail(400, { form });
		}

		try {
			const workshop = await createWorkshop(form.data, session.user.id, platform);

			return message(form, {
				success: `Workshop "${workshop.title}" created successfully!`
			});
		} catch (error) {
			console.error('Create workshop error:', error);
			return message(
				form,
				{
					error: 'Failed to create workshop. Please try again.'
				},
				{ status: 500 }
			);
		}
	}
};
```

**File**: `src/routes/dashboard/workshops/create/+page.svelte`

```svelte
<script lang="ts">
	import { superForm } from 'sveltekit-superforms';
	import { valibotClient } from 'sveltekit-superforms/adapters';
	import { CreateWorkshopSchema } from '$lib/schemas/workshops';
	import { Button } from '$lib/components/ui/button';
	import { Input } from '$lib/components/ui/input';
	import { Textarea } from '$lib/components/ui/textarea';
	import { Switch } from '$lib/components/ui/switch';
	import { Alert } from '$lib/components/ui/alert';
	import * as Form from '$lib/components/ui/form';
	import { LoaderCircle, CheckCircled } from 'lucide-svelte';
	import { goto } from '$app/navigation';

	const { data } = $props();

	const form = superForm(data.form, {
		validators: valibotClient(CreateWorkshopSchema),
		validationMethod: 'onblur',
		onSuccess: () => goto('/dashboard/workshops')
	});

	const { form: formData, enhance, errors, submitting, message } = form;
</script>

<div class="space-y-6">
	<div class="flex justify-between items-center">
		<h1 class="text-3xl font-bold">Create Workshop</h1>
		<Button variant="outline" href="/dashboard/workshops">Back to Workshops</Button>
	</div>

	<!-- Success message -->
	{#if $message?.success}
		<Alert.Root variant="success">
			<CheckCircled class="h-4 w-4" />
			<Alert.Description>{$message.success}</Alert.Description>
		</Alert.Root>
	{/if}

	<!-- Error message -->
	{#if $message?.error}
		<Alert.Root variant="destructive">
			<Alert.Description>{$message.error}</Alert.Description>
		</Alert.Root>
	{/if}

	<form method="POST" use:enhance class="space-y-6">
		<Form.Field {form} name="title">
			<Form.Control>
				{#snippet children({ props })}
					<Form.Label required>Title</Form.Label>
					<Input {...props} bind:value={$formData.title} placeholder="Enter workshop title" />
				{/snippet}
			</Form.Control>
			<Form.FieldErrors />
		</Form.Field>

		<Form.Field {form} name="description">
			<Form.Control>
				{#snippet children({ props })}
					<Form.Label>Description</Form.Label>
					<Textarea
						{...props}
						bind:value={$formData.description}
						placeholder="Enter workshop description"
						rows={4}
					/>
				{/snippet}
			</Form.Control>
			<Form.FieldErrors />
		</Form.Field>

		<Form.Field {form} name="location">
			<Form.Control>
				{#snippet children({ props })}
					<Form.Label required>Location</Form.Label>
					<Input {...props} bind:value={$formData.location} placeholder="Enter workshop location" />
				{/snippet}
			</Form.Control>
			<Form.FieldErrors />
		</Form.Field>

		<div class="grid grid-cols-2 gap-4">
			<Form.Field {form} name="start_date">
				<Form.Control>
					{#snippet children({ props })}
						<Form.Label required>Start Date</Form.Label>
						<Input {...props} type="datetime-local" bind:value={$formData.start_date} />
					{/snippet}
				</Form.Control>
				<Form.FieldErrors />
			</Form.Field>

			<Form.Field {form} name="end_date">
				<Form.Control>
					{#snippet children({ props })}
						<Form.Label required>End Date</Form.Label>
						<Input {...props} type="datetime-local" bind:value={$formData.end_date} />
					{/snippet}
				</Form.Control>
				<Form.FieldErrors />
			</Form.Field>
		</div>

		<Form.Field {form} name="max_capacity">
			<Form.Control>
				{#snippet children({ props })}
					<Form.Label required>Maximum Capacity</Form.Label>
					<Input
						{...props}
						type="number"
						min="1"
						bind:value={$formData.max_capacity}
						placeholder="Enter maximum capacity"
					/>
				{/snippet}
			</Form.Control>
			<Form.FieldErrors />
		</Form.Field>

		<div class="grid grid-cols-2 gap-4">
			<Form.Field {form} name="price_member">
				<Form.Control>
					{#snippet children({ props })}
						<Form.Label required>Member Price (€)</Form.Label>
						<Input
							{...props}
							type="number"
							min="0"
							step="0.01"
							bind:value={$formData.price_member}
							placeholder="0.00"
						/>
					{/snippet}
				</Form.Control>
				<Form.FieldErrors />
			</Form.Field>

			<Form.Field {form} name="price_non_member">
				<Form.Control>
					{#snippet children({ props })}
						<Form.Label required>Non-Member Price (€)</Form.Label>
						<Input
							{...props}
							type="number"
							min="0"
							step="0.01"
							bind:value={$formData.price_non_member}
							placeholder="0.00"
						/>
					{/snippet}
				</Form.Control>
				<Form.FieldErrors />
			</Form.Field>
		</div>

		<Form.Field {form} name="is_public">
			<Form.Control>
				{#snippet children({ props })}
					<div class="flex items-center space-x-2">
						<Switch {...props} id="is_public" bind:checked={$formData.is_public} />
						<Form.Label for="is_public">Public Workshop</Form.Label>
					</div>
				{/snippet}
			</Form.Control>
			<Form.FieldErrors />
		</Form.Field>

		<Form.Field {form} name="refund_days">
			<Form.Control>
				{#snippet children({ props })}
					<Form.Label>Refund Days (leave empty for no refunds)</Form.Label>
					<Input
						{...props}
						type="number"
						min="0"
						bind:value={$formData.refund_days}
						placeholder="e.g., 3 for 3 days before"
					/>
				{/snippet}
			</Form.Control>
			<Form.FieldErrors />
		</Form.Field>

		<Button type="submit" disabled={$submitting} class="w-full">
			{#if $submitting}
				<LoaderCircle class="mr-2 h-4 w-4 animate-spin" />
				Creating Workshop...
			{:else}
				Create Workshop
			{/if}
		</Button>
	</form>
</div>
```

**File**: `src/lib/components/workshops/workshop-list.svelte`

```svelte
<script lang="ts">
	import { Badge } from '$lib/components/ui/badge';
	import { Button } from '$lib/components/ui/button';
	import { Card, CardContent, CardHeader, CardTitle } from '$lib/components/ui/card';
	import type { ClubActivity } from '$lib/types/workshops';

	interface Props {
		workshops: ClubActivity[];
		onEdit: (workshop: ClubActivity) => void;
		onDelete: (workshop: ClubActivity) => void;
		onPublish: (workshop: ClubActivity) => void;
		onCancel: (workshop: ClubActivity) => void;
	}

	let { workshops, onEdit, onDelete, onPublish, onCancel }: Props = $props();

	function getStatusColor(status: string) {
		switch (status) {
			case 'planned':
				return 'bg-yellow-500';
			case 'published':
				return 'bg-green-500';
			case 'finished':
				return 'bg-blue-500';
			case 'cancelled':
				return 'bg-red-500';
			default:
				return 'bg-gray-500';
		}
	}

	function formatDateTime(dateString: string) {
		return new Date(dateString).toLocaleString();
	}
</script>

<div class="space-y-4">
	{#each workshops as workshop}
		<Card>
			<CardHeader>
				<div class="flex justify-between items-start">
					<CardTitle>{workshop.title}</CardTitle>
					<Badge class={getStatusColor(workshop.status)}>
						{workshop.status}
					</Badge>
				</div>
			</CardHeader>
			<CardContent>
				<div class="space-y-2">
					<p class="text-sm text-gray-600">{workshop.description}</p>
					<div class="grid grid-cols-2 gap-4 text-sm">
						<div>
							<strong>Start:</strong>
							{formatDateTime(workshop.start_date)}
						</div>
						<div>
							<strong>End:</strong>
							{formatDateTime(workshop.end_date)}
						</div>
						<div>
							<strong>Location:</strong>
							{workshop.location || 'TBD'}
						</div>
						<div>
							<strong>Capacity:</strong>
							{workshop.max_capacity}
						</div>
					</div>
					<div class="flex gap-2 mt-4">
						<Button variant="outline" size="sm" onclick={() => onEdit(workshop)}>Edit</Button>

						{#if workshop.status === 'planned'}
							<Button variant="default" size="sm" onclick={() => onPublish(workshop)}>
								Publish
							</Button>
						{/if}

						{#if workshop.status === 'planned' || workshop.status === 'published'}
							<Button variant="destructive" size="sm" onclick={() => onCancel(workshop)}>
								Cancel
							</Button>
						{/if}

						{#if workshop.status === 'planned'}
							<Button variant="destructive" size="sm" onclick={() => onDelete(workshop)}>
								Delete
							</Button>
						{/if}
					</div>
				</div>
			</CardContent>
		</Card>
	{/each}
</div>
```

### 7. Query Hooks (`src/lib/queries/`)

**File**: `src/lib/queries/workshops.ts`

```typescript
import { createQuery, createMutation } from '@tanstack/svelte-query';
import { supabase } from '$lib/supabase';
import type { WorkshopFormData } from '$lib/types/workshops';

export function useWorkshops() {
	return createQuery({
		queryKey: ['workshops'],
		queryFn: async () => {
			const { data, error } = await supabase
				.from('club_activities')
				.select('*')
				.order('start_date', { ascending: true });

			if (error) throw error;
			return data;
		}
	});
}

export function useWorkshop(id: string) {
	return createQuery({
		queryKey: ['workshop', id],
		queryFn: async () => {
			const { data, error } = await supabase
				.from('club_activities')
				.select('*')
				.eq('id', id)
				.single();

			if (error) throw error;
			return data;
		}
	});
}

export function useCreateWorkshop() {
	return createMutation({
		mutationFn: async (data: WorkshopFormData) => {
			const response = await fetch('/api/workshops', {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify(data)
			});

			if (!response.ok) throw new Error('Failed to create workshop');
			return response.json();
		}
	});
}

export function useUpdateWorkshop() {
	return createMutation({
		mutationFn: async ({ id, data }: { id: string; data: WorkshopFormData }) => {
			const response = await fetch(`/api/workshops/${id}`, {
				method: 'PUT',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify(data)
			});

			if (!response.ok) throw new Error('Failed to update workshop');
			return response.json();
		}
	});
}

export function useDeleteWorkshop() {
	return createMutation({
		mutationFn: async (id: string) => {
			const response = await fetch(`/api/workshops/${id}`, {
				method: 'DELETE'
			});

			if (!response.ok) throw new Error('Failed to delete workshop');
			return response.json();
		}
	});
}

export function usePublishWorkshop() {
	return createMutation({
		mutationFn: async (id: string) => {
			const response = await fetch(`/api/workshops/${id}/publish`, {
				method: 'POST'
			});

			if (!response.ok) throw new Error('Failed to publish workshop');
			return response.json();
		}
	});
}

export function useCancelWorkshop() {
	return createMutation({
		mutationFn: async (id: string) => {
			const response = await fetch(`/api/workshops/${id}/cancel`, {
				method: 'POST'
			});

			if (!response.ok) throw new Error('Failed to cancel workshop');
			return response.json();
		}
	});
}
```

### 8. Frontend Routes (`src/routes/dashboard/workshops/`)

**File**: `src/routes/dashboard/workshops/+page.svelte`

```svelte
<script lang="ts">
	import { goto } from '$app/navigation';
	import { Button } from '$lib/components/ui/button';
	import { useWorkshops } from '$lib/queries/workshops';
	import WorkshopList from '$lib/components/workshops/workshop-list.svelte';
	import type { ClubActivity } from '$lib/types/workshops';

	const workshopsQuery = useWorkshops();

	function handleCreate() {
		goto('/dashboard/workshops/create');
	}

	function handleEdit(workshop: ClubActivity) {
		goto(`/dashboard/workshops/${workshop.id}/edit`);
	}

	function handleDelete(workshop: ClubActivity) {
		// Implement delete logic
	}

	function handlePublish(workshop: ClubActivity) {
		// Implement publish logic
	}

	function handleCancel(workshop: ClubActivity) {
		// Implement cancel logic
	}
</script>

<div class="space-y-6">
	<div class="flex justify-between items-center">
		<h1 class="text-3xl font-bold">Workshops</h1>
		<Button onclick={handleCreate}>Create Workshop</Button>
	</div>

	{#if $workshopsQuery.isLoading}
		<div>Loading workshops...</div>
	{:else if $workshopsQuery.error}
		<div class="text-red-500">Error: {$workshopsQuery.error.message}</div>
	{:else if $workshopsQuery.data}
		<WorkshopList
			workshops={$workshopsQuery.data}
			onEdit={handleEdit}
			onDelete={handleDelete}
			onPublish={handlePublish}
			onCancel={handleCancel}
		/>
	{/if}
</div>
```

### 9. Test Files

**File**: `tests/workshops.test.ts`

```typescript
import { expect, test } from '@playwright/test';
import { makeAuthenticatedRequest } from './helpers/auth';

test.describe('Workshop Management', () => {
	test('should create workshop', async ({ page }) => {
		const timestamp = Date.now();
		const randomSuffix = Math.random().toString(36).substring(2, 15);

		const workshopData = {
			title: `Test Workshop ${timestamp}`,
			description: 'Test description',
			location: 'Test location',
			start_date: new Date(Date.now() + 86400000).toISOString(),
			end_date: new Date(Date.now() + 90000000).toISOString(),
			max_capacity: 10,
			price_member: 1000,
			price_non_member: 2000,
			is_public: true,
			refund_days: 3
		};

		const response = await makeAuthenticatedRequest(page, '/api/workshops', {
			method: 'POST',
			data: workshopData
		});

		expect(response.success).toBe(true);
		expect(response.workshop.title).toBe(workshopData.title);
	});

	test('should update workshop', async ({ page }) => {
		// Create workshop first
		const createResponse = await makeAuthenticatedRequest(page, '/api/workshops', {
			method: 'POST',
			data: {
				title: 'Original Title',
				start_date: new Date(Date.now() + 86400000).toISOString(),
				end_date: new Date(Date.now() + 90000000).toISOString(),
				max_capacity: 10,
				price_member: 1000,
				price_non_member: 2000,
				is_public: true,
				refund_days: 3
			}
		});

		const workshopId = createResponse.workshop.id;

		// Update workshop
		const updateResponse = await makeAuthenticatedRequest(page, `/api/workshops/${workshopId}`, {
			method: 'PUT',
			data: { title: 'Updated Title' }
		});

		expect(updateResponse.success).toBe(true);
		expect(updateResponse.workshop.title).toBe('Updated Title');
	});

	test('should publish workshop', async ({ page }) => {
		// Create workshop first
		const createResponse = await makeAuthenticatedRequest(page, '/api/workshops', {
			method: 'POST',
			data: {
				title: 'Test Workshop',
				start_date: new Date(Date.now() + 86400000).toISOString(),
				end_date: new Date(Date.now() + 90000000).toISOString(),
				max_capacity: 10,
				price_member: 1000,
				price_non_member: 2000,
				is_public: true,
				refund_days: 3
			}
		});

		const workshopId = createResponse.workshop.id;

		// Publish workshop
		const publishResponse = await makeAuthenticatedRequest(
			page,
			`/api/workshops/${workshopId}/publish`,
			{
				method: 'POST'
			}
		);

		expect(publishResponse.success).toBe(true);
		expect(publishResponse.workshop.status).toBe('published');
	});
});
```

This technical implementation follows your project's established patterns with:

- Database schema with proper RLS policies
- Kysely for mutations with `executeWithRLS()`
- Valibot for validation
- TanStack Query for state management
- Svelte 5 syntax with runes
- Consistent API response format `{success: true, resource: data}`
- Role-based authorization for coordinators
- Comprehensive testing approach
