# Stage 1: Low-Level Technical Implementation

## Technical Implementation Plan

### 1. Database Schema (`supabase/migrations/`)

**Migration file**: `20240101000000_create_club_activities.sql`

```sql
-- Create enums
CREATE TYPE club_activity_status AS ENUM ('planned', 'published', 'finished', 'cancelled');
CREATE TYPE refund_policy AS ENUM ('no_refund', '1_day', '3_days', '1_week');

-- Create club_activities table
CREATE TABLE club_activities (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title VARCHAR(255) NOT NULL,
    description TEXT,
    location VARCHAR(255),
    start_date TIMESTAMPTZ NOT NULL,
    end_date TIMESTAMPTZ NOT NULL,
    max_capacity INTEGER NOT NULL CHECK (max_capacity > 0),
    price_member INTEGER NOT NULL CHECK (price_member >= 0), -- cents
    price_non_member INTEGER NOT NULL CHECK (price_non_member >= 0), -- cents
    is_public BOOLEAN DEFAULT true,
    refund_policy refund_policy DEFAULT '3_days',
    status club_activity_status DEFAULT 'planned',
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now(),
    created_by UUID REFERENCES auth.users(id)
);

-- RLS policies
ALTER TABLE club_activities ENABLE ROW LEVEL SECURITY;

-- Policy for workshop coordinators
CREATE POLICY "Workshop coordinators can manage activities" ON club_activities
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM user_roles ur
            JOIN roles r ON ur.role_id = r.id
            WHERE ur.user_id = auth.uid() 
            AND r.name IN ('admin', 'president', 'beginners_coordinator')
        )
    );

-- Triggers for updated_at
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER update_club_activities_updated_at 
    BEFORE UPDATE ON club_activities 
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
```

### 2. TypeScript Types (`src/lib/types/`)

**File**: `src/lib/types/workshops.ts`

```typescript
import type { Database } from '../database.types';

export type ClubActivity = Database['public']['Tables']['club_activities']['Row'];
export type ClubActivityInsert = Database['public']['Tables']['club_activities']['Insert'];
export type ClubActivityUpdate = Database['public']['Tables']['club_activities']['Update'];
export type ClubActivityStatus = Database['public']['Enums']['club_activity_status'];
export type RefundPolicy = Database['public']['Enums']['refund_policy'];

export interface WorkshopFormData {
    title: string;
    description?: string;
    location?: string;
    start_date: string;
    end_date: string;
    max_capacity: number;
    price_member: number;
    price_non_member: number;
    is_public: boolean;
    refund_policy: RefundPolicy;
}
```

### 3. Kysely Models (`src/lib/server/`)

**File**: `src/lib/server/workshops.ts`

```typescript
import { executeWithRLS } from './kysely';
import type { ClubActivityInsert, ClubActivityUpdate } from '../types/workshops';

export async function createWorkshop(
    data: ClubActivityInsert,
    userId: string
): Promise<ClubActivity> {
    const result = await executeWithRLS(
        (db) => db
            .insertInto('club_activities')
            .values({ ...data, created_by: userId })
            .returning('*')
            .executeTakeFirstOrThrow(),
        userId
    );
    return result;
}

export async function updateWorkshop(
    id: string,
    data: ClubActivityUpdate,
    userId: string
): Promise<ClubActivity> {
    const result = await executeWithRLS(
        (db) => db
            .updateTable('club_activities')
            .set(data)
            .where('id', '=', id)
            .returning('*')
            .executeTakeFirstOrThrow(),
        userId
    );
    return result;
}

export async function deleteWorkshop(id: string, userId: string): Promise<void> {
    await executeWithRLS(
        (db) => db
            .deleteFrom('club_activities')
            .where('id', '=', id)
            .execute(),
        userId
    );
}

export async function publishWorkshop(id: string, userId: string): Promise<ClubActivity> {
    const result = await executeWithRLS(
        (db) => db
            .updateTable('club_activities')
            .set({ status: 'published' })
            .where('id', '=', id)
            .where('status', '=', 'planned')
            .returning('*')
            .executeTakeFirstOrThrow(),
        userId
    );
    return result;
}

export async function cancelWorkshop(id: string, userId: string): Promise<ClubActivity> {
    const result = await executeWithRLS(
        (db) => db
            .updateTable('club_activities')
            .set({ status: 'cancelled' })
            .where('id', '=', id)
            .where('status', 'in', ['planned', 'published'])
            .returning('*')
            .executeTakeFirstOrThrow(),
        userId
    );
    return result;
}
```

### 4. Validation Schemas (`src/lib/schemas/`)

**File**: `src/lib/schemas/workshops.ts`

```typescript
import * as v from 'valibot';

export const CreateWorkshopSchema = v.object({
    title: v.pipe(v.string(), v.minLength(1, 'Title is required'), v.maxLength(255)),
    description: v.optional(v.string()),
    location: v.optional(v.pipe(v.string(), v.maxLength(255))),
    start_date: v.pipe(v.string(), v.isoDateTime()),
    end_date: v.pipe(v.string(), v.isoDateTime()),
    max_capacity: v.pipe(v.number(), v.minValue(1, 'Capacity must be at least 1')),
    price_member: v.pipe(v.number(), v.minValue(0, 'Price cannot be negative')),
    price_non_member: v.pipe(v.number(), v.minValue(0, 'Price cannot be negative')),
    is_public: v.boolean(),
    refund_policy: v.picklist(['no_refund', '1_day', '3_days', '1_week'])
});

export const UpdateWorkshopSchema = v.partial(CreateWorkshopSchema);
```

### 5. API Endpoints (`src/routes/api/workshops/`)

**File**: `src/routes/api/workshops/+server.ts`

```typescript
import { json } from '@sveltejs/kit';
import { safeGetSession } from '$lib/server/auth';
import { createWorkshop } from '$lib/server/workshops';
import { CreateWorkshopSchema } from '$lib/schemas/workshops';
import { parse } from 'valibot';
import { authorize } from '$lib/server/roles';

export async function POST({ request, locals }) {
    try {
        const session = await safeGetSession(locals);
        await authorize(session, ['admin', 'president', 'beginners_coordinator']);
        
        const body = await request.json();
        const validated = parse(CreateWorkshopSchema, body);
        
        const workshop = await createWorkshop(validated, session.user.id);
        
        return json({ success: true, workshop });
    } catch (error) {
        console.error('Create workshop error:', error);
        return json({ success: false, error: error.message }, { status: 400 });
    }
}
```

**File**: `src/routes/api/workshops/[id]/+server.ts`

```typescript
import { json } from '@sveltejs/kit';
import { safeGetSession } from '$lib/server/auth';
import { updateWorkshop, deleteWorkshop } from '$lib/server/workshops';
import { UpdateWorkshopSchema } from '$lib/schemas/workshops';
import { parse } from 'valibot';
import { authorize } from '$lib/server/roles';

export async function PUT({ request, locals, params }) {
    try {
        const session = await safeGetSession(locals);
        await authorize(session, ['admin', 'president', 'beginners_coordinator']);
        
        const body = await request.json();
        const validated = parse(UpdateWorkshopSchema, body);
        
        const workshop = await updateWorkshop(params.id, validated, session.user.id);
        
        return json({ success: true, workshop });
    } catch (error) {
        console.error('Update workshop error:', error);
        return json({ success: false, error: error.message }, { status: 400 });
    }
}

export async function DELETE({ locals, params }) {
    try {
        const session = await safeGetSession(locals);
        await authorize(session, ['admin', 'president', 'beginners_coordinator']);
        
        await deleteWorkshop(params.id, session.user.id);
        
        return json({ success: true });
    } catch (error) {
        console.error('Delete workshop error:', error);
        return json({ success: false, error: error.message }, { status: 400 });
    }
}
```

**File**: `src/routes/api/workshops/[id]/publish/+server.ts`

```typescript
import { json } from '@sveltejs/kit';
import { safeGetSession } from '$lib/server/auth';
import { publishWorkshop } from '$lib/server/workshops';
import { authorize } from '$lib/server/roles';

export async function POST({ locals, params }) {
    try {
        const session = await safeGetSession(locals);
        await authorize(session, ['admin', 'president', 'beginners_coordinator']);
        
        const workshop = await publishWorkshop(params.id, session.user.id);
        
        return json({ success: true, workshop });
    } catch (error) {
        console.error('Publish workshop error:', error);
        return json({ success: false, error: error.message }, { status: 400 });
    }
}
```

**File**: `src/routes/api/workshops/[id]/cancel/+server.ts`

```typescript
import { json } from '@sveltejs/kit';
import { safeGetSession } from '$lib/server/auth';
import { cancelWorkshop } from '$lib/server/workshops';
import { authorize } from '$lib/server/roles';

export async function POST({ locals, params }) {
    try {
        const session = await safeGetSession(locals);
        await authorize(session, ['admin', 'president', 'beginners_coordinator']);
        
        const workshop = await cancelWorkshop(params.id, session.user.id);
        
        return json({ success: true, workshop });
    } catch (error) {
        console.error('Cancel workshop error:', error);
        return json({ success: false, error: error.message }, { status: 400 });
    }
}
```

### 6. Frontend Components (`src/lib/components/workshops/`)

**File**: `src/lib/components/workshops/workshop-form.svelte`

```svelte
<script lang="ts">
import { createMutation, createQuery } from '@tanstack/svelte-query';
import { Button } from '$lib/components/ui/button';
import { Input } from '$lib/components/ui/input';
import { Label } from '$lib/components/ui/label';
import { Textarea } from '$lib/components/ui/textarea';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '$lib/components/ui/select';
import { Switch } from '$lib/components/ui/switch';
import type { WorkshopFormData } from '$lib/types/workshops';

interface Props {
    initialData?: WorkshopFormData;
    onSubmit: (data: WorkshopFormData) => void;
    isLoading?: boolean;
}

let { initialData, onSubmit, isLoading = false }: Props = $props();

let formData = $state({
    title: initialData?.title ?? '',
    description: initialData?.description ?? '',
    location: initialData?.location ?? '',
    start_date: initialData?.start_date ?? '',
    end_date: initialData?.end_date ?? '',
    max_capacity: initialData?.max_capacity ?? 10,
    price_member: initialData?.price_member ?? 0,
    price_non_member: initialData?.price_non_member ?? 0,
    is_public: initialData?.is_public ?? true,
    refund_policy: initialData?.refund_policy ?? '3_days'
});

function handleSubmit() {
    onSubmit(formData);
}
</script>

<form on:submit|preventDefault={handleSubmit} class="space-y-4">
    <div>
        <Label for="title">Title</Label>
        <Input id="title" bind:value={formData.title} required />
    </div>
    
    <div>
        <Label for="description">Description</Label>
        <Textarea id="description" bind:value={formData.description} />
    </div>
    
    <div>
        <Label for="location">Location</Label>
        <Input id="location" bind:value={formData.location} />
    </div>
    
    <div class="grid grid-cols-2 gap-4">
        <div>
            <Label for="start_date">Start Date</Label>
            <Input id="start_date" type="datetime-local" bind:value={formData.start_date} required />
        </div>
        <div>
            <Label for="end_date">End Date</Label>
            <Input id="end_date" type="datetime-local" bind:value={formData.end_date} required />
        </div>
    </div>
    
    <div>
        <Label for="max_capacity">Maximum Capacity</Label>
        <Input id="max_capacity" type="number" min="1" bind:value={formData.max_capacity} required />
    </div>
    
    <div class="grid grid-cols-2 gap-4">
        <div>
            <Label for="price_member">Member Price (cents)</Label>
            <Input id="price_member" type="number" min="0" bind:value={formData.price_member} required />
        </div>
        <div>
            <Label for="price_non_member">Non-Member Price (cents)</Label>
            <Input id="price_non_member" type="number" min="0" bind:value={formData.price_non_member} required />
        </div>
    </div>
    
    <div class="flex items-center space-x-2">
        <Switch id="is_public" bind:checked={formData.is_public} />
        <Label for="is_public">Public Workshop</Label>
    </div>
    
    <div>
        <Label for="refund_policy">Refund Policy</Label>
        <Select bind:value={formData.refund_policy}>
            <SelectTrigger>
                <SelectValue placeholder="Select refund policy" />
            </SelectTrigger>
            <SelectContent>
                <SelectItem value="no_refund">No Refund</SelectItem>
                <SelectItem value="1_day">1 Day Before</SelectItem>
                <SelectItem value="3_days">3 Days Before</SelectItem>
                <SelectItem value="1_week">1 Week Before</SelectItem>
            </SelectContent>
        </Select>
    </div>
    
    <Button type="submit" disabled={isLoading}>
        {isLoading ? 'Saving...' : 'Save Workshop'}
    </Button>
</form>
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
        case 'planned': return 'bg-yellow-500';
        case 'published': return 'bg-green-500';
        case 'finished': return 'bg-blue-500';
        case 'cancelled': return 'bg-red-500';
        default: return 'bg-gray-500';
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
                            <strong>Start:</strong> {formatDateTime(workshop.start_date)}
                        </div>
                        <div>
                            <strong>End:</strong> {formatDateTime(workshop.end_date)}
                        </div>
                        <div>
                            <strong>Location:</strong> {workshop.location || 'TBD'}
                        </div>
                        <div>
                            <strong>Capacity:</strong> {workshop.max_capacity}
                        </div>
                    </div>
                    <div class="flex gap-2 mt-4">
                        <Button variant="outline" size="sm" onclick={() => onEdit(workshop)}>
                            Edit
                        </Button>
                        
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
            refund_policy: '3_days'
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
                refund_policy: '3_days'
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
                refund_policy: '3_days'
            }
        });
        
        const workshopId = createResponse.workshop.id;
        
        // Publish workshop
        const publishResponse = await makeAuthenticatedRequest(page, `/api/workshops/${workshopId}/publish`, {
            method: 'POST'
        });
        
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