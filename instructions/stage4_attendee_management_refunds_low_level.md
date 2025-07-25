# Stage 4: Attendee Management & Refund System - Low Level Design COMPLETED

## Overview
This document provides detailed implementation specifications for the attendee management and refund system, following the project's established patterns and architecture.

## Database Design

### 1. Refund Tracking Table Migration

**File**: `pnpm supabase migrations new add_refunds_and_attendance`

```sql
-- Refund status enum
CREATE TYPE refund_status AS ENUM ('pending', 'processing', 'completed', 'failed', 'cancelled');

-- Refunds table
CREATE TABLE club_activity_refunds (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    registration_id       UUID NOT NULL REFERENCES club_activity_registrations(id) ON DELETE CASCADE,
    
    -- Refund details
    refund_amount         INTEGER NOT NULL, -- in cents
    refund_reason         TEXT,
    status                refund_status NOT NULL DEFAULT 'pending',
    
    -- Stripe integration
    stripe_refund_id      TEXT UNIQUE,
    stripe_payment_intent_id TEXT,
    
    -- Timestamps
    requested_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    processed_at          TIMESTAMPTZ,
    completed_at          TIMESTAMPTZ,
    
    -- Audit fields
    requested_by          UUID REFERENCES auth.users(id),
    processed_by          UUID REFERENCES auth.users(id),
    
    created_at            TIMESTAMPTZ DEFAULT NOW(),
    updated_at            TIMESTAMPTZ DEFAULT NOW(),
    
    -- Constraints
    CONSTRAINT refund_amount_positive CHECK (refund_amount > 0),
    CONSTRAINT one_refund_per_registration UNIQUE (registration_id)
);

-- Indexes
CREATE INDEX idx_refunds_registration ON club_activity_refunds (registration_id);
CREATE INDEX idx_refunds_status ON club_activity_refunds (status);
CREATE INDEX idx_refunds_stripe_refund ON club_activity_refunds (stripe_refund_id);
CREATE INDEX idx_refunds_requested_at ON club_activity_refunds (requested_at);

-- RLS Policies
ALTER TABLE club_activity_refunds ENABLE ROW LEVEL SECURITY;

-- Members can view their own refunds
CREATE POLICY "Members can view own refunds" ON club_activity_refunds
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM club_activity_registrations car
            WHERE car.id = registration_id 
            AND car.member_user_id = (SELECT auth.uid())
        )
    );

-- Committee can view all refunds
CREATE POLICY "Committee can view all refunds" ON club_activity_refunds
    FOR SELECT USING (
        has_any_role((SELECT auth.uid()), ARRAY['admin', 'president', 'workshop_coordinator']::role_type[])
    );

-- Committee can manage refunds
CREATE POLICY "Committee can manage refunds" ON club_activity_refunds
    FOR ALL USING (
        has_any_role((SELECT auth.uid()), ARRAY['admin', 'president', 'workshop_coordinator']::role_type[])
    );

-- Add attendance tracking to existing registrations table
ALTER TABLE club_activity_registrations 
ADD COLUMN attendance_status TEXT CHECK (attendance_status IN ('pending', 'attended', 'no_show', 'excused')) DEFAULT 'pending',
ADD COLUMN attendance_marked_at TIMESTAMPTZ,
ADD COLUMN attendance_marked_by UUID REFERENCES auth.users(id),
ADD COLUMN attendance_notes TEXT;

-- Index for attendance queries
CREATE INDEX idx_registrations_attendance_status ON club_activity_registrations (attendance_status);
CREATE INDEX idx_registrations_attendance_marked_at ON club_activity_registrations (attendance_marked_at);

-- Update trigger for refunds
CREATE TRIGGER update_club_activity_refunds_updated_at
    BEFORE UPDATE ON club_activity_refunds
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

### 2. Database Functions

```sql
-- Function to check refund eligibility
CREATE OR REPLACE FUNCTION check_refund_eligibility(registration_id UUID)
RETURNS BOOLEAN AS $$
DECLARE
    reg_record RECORD;
    workshop_record RECORD;
    refund_deadline TIMESTAMPTZ;
BEGIN
    -- Get registration details
    SELECT car.*, ca.start_date, ca.refund_days, ca.status as workshop_status
    INTO reg_record, workshop_record
    FROM club_activity_registrations car
    JOIN club_activities ca ON car.club_activity_id = ca.id
    WHERE car.id = registration_id;
    
    -- Check if registration exists
    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;
    
    -- Check if already refunded
    IF EXISTS (SELECT 1 FROM club_activity_refunds WHERE registration_id = registration_id) THEN
        RETURN FALSE;
    END IF;
    
    -- Check if registration is confirmed/paid
    IF reg_record.status NOT IN ('confirmed', 'pending') THEN
        RETURN FALSE;
    END IF;
    
    -- Check workshop status
    IF workshop_record.workshop_status IN ('finished', 'cancelled') THEN
        RETURN FALSE;
    END IF;
    
    -- Check refund deadline if set
    IF workshop_record.refund_days IS NOT NULL THEN
        refund_deadline := workshop_record.start_date - (workshop_record.refund_days || ' days')::INTERVAL;
        IF NOW() > refund_deadline THEN
            RETURN FALSE;
        END IF;
    END IF;
    
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to calculate refund amount
CREATE OR REPLACE FUNCTION calculate_refund_amount(registration_id UUID)
RETURNS INTEGER AS $$
DECLARE
    amount_paid INTEGER;
BEGIN
    SELECT car.amount_paid INTO amount_paid
    FROM club_activity_registrations car
    WHERE car.id = registration_id;
    
    -- For now, full refund if eligible
    -- Future: could implement partial refunds based on timing
    RETURN COALESCE(amount_paid, 0);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

## API Design

### 1. Refund Management Endpoints

**File**: `src/routes/api/workshops/[id]/refunds/+server.ts`

**Note**: This implementation uses a simplified webhook-driven approach where refund status updates are handled automatically by Stripe webhooks rather than manual API endpoints.

```typescript
import { json } from '@sveltejs/kit';
import { authorize } from '$lib/server/auth';
import { WORKSHOP_ROLES } from '$lib/server/roles';
import { processRefund, getWorkshopRefunds } from '$lib/server/refunds';
import { ProcessRefundSchema } from '$lib/schemas/refunds';
import { safeParse } from 'valibot';
import type { RequestHandler } from './$types';
import * as Sentry from '@sentry/sveltekit';

export const GET: RequestHandler = async ({ locals, params, platform }) => {
    try {
        const session = await authorize(locals, WORKSHOP_ROLES);
        const refunds = await getWorkshopRefunds(params.id!, session, platform!);
        return json({ success: true, refunds });
    } catch (error) {
        Sentry.captureException(error);
        return json({ success: false, error: error.message }, { status: 500 });
    }
};

export const POST: RequestHandler = async ({ request, locals, params, platform }) => {
    try {
        const session = await authorize(locals, WORKSHOP_ROLES);
        
        const body = await request.json();
        const result = safeParse(ProcessRefundSchema, body);
        
        if (!result.success) {
            return json(
                { success: false, error: 'Invalid data', issues: result.issues },
                { status: 400 }
            );
        }
        
        const refund = await processRefund(
            result.output.registration_id,
            result.output.reason,
            session,
            platform!
        );
        
        return json({ success: true, refund });
    } catch (error) {
        Sentry.captureException(error);
        return json({ success: false, error: error.message }, { status: 500 });
    }
};
```

**Note**: Individual refund status updates are handled automatically by Stripe webhooks. Manual status updates are not implemented as they are unnecessary for the webhook-driven refund flow.

### 2. Attendance Management Endpoints

**File**: `src/routes/api/workshops/[id]/attendance/+server.ts`

```typescript
import { json } from '@sveltejs/kit';
import { authorize } from '$lib/server/auth';
import { WORKSHOP_ROLES } from '$lib/server/roles';
import { updateAttendance, getWorkshopAttendance } from '$lib/server/attendance';
import { UpdateAttendanceSchema } from '$lib/schemas/attendance';
import { safeParse } from 'valibot';
import type { RequestHandler } from './$types';
import * as Sentry from '@sentry/sveltekit';

export const GET: RequestHandler = async ({ locals, params, platform }) => {
    try {
        const session = await authorize(locals, WORKSHOP_ROLES);
        const attendance = await getWorkshopAttendance(params.id!, session, platform!);
        return json({ success: true, attendance });
    } catch (error) {
        Sentry.captureException(error);
        return json({ success: false, error: error.message }, { status: 500 });
    }
};

export const PUT: RequestHandler = async ({ request, locals, params, platform }) => {
    try {
        const session = await authorize(locals, WORKSHOP_ROLES);
        
        const body = await request.json();
        const result = safeParse(UpdateAttendanceSchema, body);
        
        if (!result.success) {
            return json(
                { success: false, error: 'Invalid data', issues: result.issues },
                { status: 400 }
            );
        }
        
        const updatedRegistrations = await updateAttendance(
            params.id!,
            result.output.attendance_updates,
            session,
            platform!
        );
        
        return json({ success: true, registrations: updatedRegistrations });
    } catch (error) {
        Sentry.captureException(error);
        return json({ success: false, error: error.message }, { status: 500 });
    }
};
```

## Server Functions

### 1. Refund Management

**File**: `src/lib/server/refunds.ts`

```typescript
import { executeWithRLS, getKyselyClient } from './kysely';
import type { Database } from '$database';
import type { Session } from '@supabase/supabase-js';
import { createStripeRefund } from './stripe';

export type ClubActivityRefund = Database['public']['Tables']['club_activity_refunds']['Row'];
export type ClubActivityRefundInsert = Database['public']['Tables']['club_activity_refunds']['Insert'];

export async function processRefund(
    registrationId: string,
    reason: string,
    session: Session,
    platform: App.Platform
): Promise<ClubActivityRefund> {
    const kysely = getKyselyClient(platform.env.HYPERDRIVE);
    
    return await executeWithRLS(kysely, { claims: session }, async (trx) => {
        // Check eligibility
        const eligibilityResult = await trx
            .selectFrom('club_activity_registrations as car')
            .innerJoin('club_activities as ca', 'car.club_activity_id', 'ca.id')
            .select([
                'car.id',
                'car.amount_paid',
                'car.stripe_checkout_session_id',
                'car.status as registration_status',
                'ca.start_date',
                'ca.refund_days',
                'ca.status as workshop_status'
            ])
            .where('car.id', '=', registrationId)
            .executeTakeFirst();
            
        if (!eligibilityResult) {
            throw new Error('Registration not found');
        }
        
        // Validate refund eligibility
        if (eligibilityResult.registration_status === 'refunded') {
            throw new Error('Registration already refunded');
        }
        
        if (eligibilityResult.workshop_status === 'finished') {
            throw new Error('Cannot refund finished workshop');
        }
        
        // Check refund deadline
        if (eligibilityResult.refund_days !== null) {
            const refundDeadline = new Date(eligibilityResult.start_date);
            refundDeadline.setDate(refundDeadline.getDate() - eligibilityResult.refund_days);
            
            if (new Date() > refundDeadline) {
                throw new Error('Refund deadline has passed');
            }
        }
        
        // Check if refund already exists
        const existingRefund = await trx
            .selectFrom('club_activity_refunds')
            .select('id')
            .where('registration_id', '=', registrationId)
            .executeTakeFirst();
            
        if (existingRefund) {
            throw new Error('Refund already requested for this registration');
        }
        
        // Create refund record
        const refund = await trx
            .insertInto('club_activity_refunds')
            .values({
                registration_id: registrationId,
                refund_amount: eligibilityResult.amount_paid,
                refund_reason: reason,
                status: 'pending',
                requested_by: session.user.id
            })
            .returning([
                'id',
                'registration_id',
                'refund_amount',
                'refund_reason',
                'status',
                'stripe_refund_id',
                'requested_at',
                'processed_at',
                'completed_at',
                'requested_by',
                'processed_by',
                'created_at',
                'updated_at'
            ])
            .executeTakeFirstOrThrow();
            
        // Update registration status
        await trx
            .updateTable('club_activity_registrations')
            .set({ status: 'refunded' })
            .where('id', '=', registrationId)
            .execute();
            
        // Process Stripe refund asynchronously
        if (eligibilityResult.stripe_checkout_session_id) {
            try {
                const stripeRefund = await createStripeRefund(
                    eligibilityResult.stripe_checkout_session_id,
                    eligibilityResult.amount_paid,
                    platform.env.STRIPE_SECRET_KEY
                );
                
                await trx
                    .updateTable('club_activity_refunds')
                    .set({
                        stripe_refund_id: stripeRefund.id,
                        status: 'processing',
                        processed_at: new Date().toISOString(),
                        processed_by: session.user.id
                    })
                    .where('id', '=', refund.id)
                    .execute();
                    
            } catch (stripeError) {
                await trx
                    .updateTable('club_activity_refunds')
                    .set({ status: 'failed' })
                    .where('id', '=', refund.id)
                    .execute();
                throw stripeError;
            }
        }
        
        return refund;
    });
}

export async function getWorkshopRefunds(
    workshopId: string,
    session: Session,
    platform: App.Platform
): Promise<ClubActivityRefund[]> {
    const kysely = getKyselyClient(platform.env.HYPERDRIVE);
    
    return await executeWithRLS(kysely, { claims: session }, async (trx) => {
        return await trx
            .selectFrom('club_activity_refunds as car')
            .innerJoin('club_activity_registrations as reg', 'car.registration_id', 'reg.id')
            .select([
                'car.id',
                'car.registration_id',
                'car.refund_amount',
                'car.refund_reason',
                'car.status',
                'car.stripe_refund_id',
                'car.requested_at',
                'car.processed_at',
                'car.completed_at',
                'car.requested_by',
                'car.processed_by',
                'car.created_at',
                'car.updated_at'
            ])
            .where('reg.club_activity_id', '=', workshopId)
            .orderBy('car.requested_at', 'desc')
            .execute();
    });
}

// Note: updateRefundStatus function removed - refund status updates are handled automatically by Stripe webhooks
```

### 2. Attendance Management

**File**: `src/lib/server/attendance.ts`

```typescript
import { executeWithRLS, getKyselyClient } from './kysely';
import type { Database } from '$database';
import type { Session } from '@supabase/supabase-js';

export type AttendanceUpdate = {
    registration_id: string;
    attendance_status: 'attended' | 'no_show' | 'excused';
    notes?: string;
};

export async function updateAttendance(
    workshopId: string,
    attendanceUpdates: AttendanceUpdate[],
    session: Session,
    platform: App.Platform
): Promise<any[]> {
    const kysely = getKyselyClient(platform.env.HYPERDRIVE);
    
    return await executeWithRLS(kysely, { claims: session }, async (trx) => {
        const results = [];
        
        for (const update of attendanceUpdates) {
            const result = await trx
                .updateTable('club_activity_registrations')
                .set({
                    attendance_status: update.attendance_status,
                    attendance_marked_at: new Date().toISOString(),
                    attendance_marked_by: session.user.id,
                    attendance_notes: update.notes || null
                })
                .where('id', '=', update.registration_id)
                .where('club_activity_id', '=', workshopId)
                .returning([
                    'id',
                    'club_activity_id',
                    'member_user_id',
                    'external_user_id',
                    'attendance_status',
                    'attendance_marked_at',
                    'attendance_marked_by',
                    'attendance_notes'
                ])
                .executeTakeFirst();
                
            if (result) {
                results.push(result);
            }
        }
        
        return results;
    });
}

export async function getWorkshopAttendance(
    workshopId: string,
    session: Session,
    platform: App.Platform
): Promise<any[]> {
    const kysely = getKyselyClient(platform.env.HYPERDRIVE);
    
    return await executeWithRLS(kysely, { claims: session }, async (trx) => {
        return await trx
            .selectFrom('club_activity_registrations as car')
            .leftJoin('user_profiles as up', 'car.member_user_id', 'up.supabase_user_id')
            .leftJoin('external_users as eu', 'car.external_user_id', 'eu.id')
            .select([
                'car.id',
                'car.club_activity_id',
                'car.status',
                'car.attendance_status',
                'car.attendance_marked_at',
                'car.attendance_marked_by',
                'car.attendance_notes',
                'up.first_name as member_first_name',
                'up.last_name as member_last_name',
                'up.email as member_email',
                'eu.first_name as external_first_name',
                'eu.last_name as external_last_name',
                'eu.email as external_email'
            ])
            .where('car.club_activity_id', '=', workshopId)
            .where('car.status', 'in', ['confirmed', 'pending'])
            .orderBy('up.last_name', 'asc')
            .orderBy('eu.last_name', 'asc')
            .execute();
    });
}
```

### 3. Stripe Integration

**File**: `src/lib/server/stripe.ts` (additions)

```typescript
// Add to existing stripe.ts file

export async function createStripeRefund(
    checkoutSessionId: string,
    amount: number,
    stripeSecretKey: string
): Promise<any> {
    const stripe = new Stripe(stripeSecretKey, { apiVersion: '2024-06-20' });
    
    // Get the payment intent from the checkout session
    const session = await stripe.checkout.sessions.retrieve(checkoutSessionId);
    
    if (!session.payment_intent) {
        throw new Error('No payment intent found for checkout session');
    }
    
    // Create the refund
    const refund = await stripe.refunds.create({
        payment_intent: session.payment_intent as string,
        amount: amount,
        reason: 'requested_by_customer'
    });
    
    return refund;
}
```

## Validation Schemas

### 1. Refund Schemas

**File**: `src/lib/schemas/refunds.ts`

```typescript
import * as v from 'valibot';

export const ProcessRefundSchema = v.object({
    registration_id: v.pipe(v.string(), v.uuid('Must be a valid UUID')),
    reason: v.pipe(
        v.string(),
        v.minLength(1, 'Reason is required'),
        v.maxLength(500, 'Reason must be less than 500 characters')
    )
});

export type ProcessRefundInput = v.InferInput<typeof ProcessRefundSchema>;

// Note: UpdateRefundStatusSchema removed - refund status updates are handled automatically by Stripe webhooks
```

### 2. Attendance Schemas

**File**: `src/lib/schemas/attendance.ts`

```typescript
import * as v from 'valibot';

export const AttendanceUpdateSchema = v.object({
    registration_id: v.pipe(v.string(), v.uuid('Must be a valid UUID')),
    attendance_status: v.picklist(['attended', 'no_show', 'excused']),
    notes: v.optional(v.pipe(v.string(), v.maxLength(500, 'Notes must be less than 500 characters')))
});

export const UpdateAttendanceSchema = v.object({
    attendance_updates: v.array(AttendanceUpdateSchema, 'At least one attendance update required')
});

export type AttendanceUpdateInput = v.InferInput<typeof AttendanceUpdateSchema>;
export type UpdateAttendanceInput = v.InferInput<typeof UpdateAttendanceSchema>;
```

## Frontend Components

### 1. Attendee Management Page

**File**: `src/routes/dashboard/workshops/[id]/attendees/+page.svelte`

```svelte
<script lang="ts">
    import { page } from '$app/stores';
    import { createQuery, createMutation, useQueryClient } from '@tanstack/svelte-query';
    import { Button } from '$lib/components/ui/button';
    import { Card, CardContent, CardHeader, CardTitle } from '$lib/components/ui/card';
    import { Badge } from '$lib/components/ui/badge';
    import AttendanceTracker from '$lib/components/workshops/attendance-tracker.svelte';
    import RefundManager from '$lib/components/workshops/refund-manager.svelte';
    import { toast } from 'svelte-sonner';
    
    const workshopId = $page.params.id;
    const queryClient = useQueryClient();
    
    // Fetch attendees
    const attendeesQuery = createQuery(() => ({
        queryKey: ['workshop-attendees', workshopId],
        queryFn: async () => {
            const response = await fetch(`/api/workshops/${workshopId}/attendance`);
            if (!response.ok) throw new Error('Failed to fetch attendees');
            const data = await response.json();
            return data.attendance;
        }
    }));
    
    // Fetch refunds
    const refundsQuery = createQuery(() => ({
        queryKey: ['workshop-refunds', workshopId],
        queryFn: async () => {
            const response = await fetch(`/api/workshops/${workshopId}/refunds`);
            if (!response.ok) throw new Error('Failed to fetch refunds');
            const data = await response.json();
            return data.refunds;
        }
    }));
    
    function getAttendeeDisplayName(attendee: any) {
        return attendee.member_first_name 
            ? `${attendee.member_first_name} ${attendee.member_last_name}`
            : `${attendee.external_first_name} ${attendee.external_last_name}`;
    }
    
    function getAttendeeEmail(attendee: any) {
        return attendee.member_email || attendee.external_email;
    }
    
    function getStatusBadgeVariant(status: string) {
        switch (status) {
            case 'attended': return 'default';
            case 'no_show': return 'destructive';
            case 'excused': return 'secondary';
            default: return 'outline';
        }
    }
</script>

<div class="container mx-auto py-6">
    <div class="mb-6">
        <h1 class="text-3xl font-bold">Workshop Attendees</h1>
        <p class="text-muted-foreground">Manage attendance and process refunds</p>
    </div>
    
    <div class="grid gap-6 lg:grid-cols-3">
        <!-- Attendee List -->
        <div class="lg:col-span-2">
            <Card>
                <CardHeader>
                    <CardTitle>Registered Attendees</CardTitle>
                </CardHeader>
                <CardContent>
                    {#if $attendeesQuery.isLoading}
                        <div class="flex items-center justify-center py-8">
                            <div class="animate-spin rounded-full h-8 w-8 border-b-2 border-primary"></div>
                        </div>
                    {:else if $attendeesQuery.error}
                        <div class="text-center py-8 text-destructive">
                            Failed to load attendees
                        </div>
                    {:else if $attendeesQuery.data?.length === 0}
                        <div class="text-center py-8 text-muted-foreground">
                            No attendees registered yet
                        </div>
                    {:else}
                        <AttendanceTracker 
                            attendees={$attendeesQuery.data} 
                            {workshopId}
                            on:attendanceUpdated={() => {
                                queryClient.invalidateQueries({ queryKey: ['workshop-attendees', workshopId] });
                                toast.success('Attendance updated successfully');
                            }}
                        />
                    {/if}
                </CardContent>
            </Card>
        </div>
        
        <!-- Refund Management -->
        <div>
            <Card>
                <CardHeader>
                    <CardTitle>Refund Management</CardTitle>
                </CardHeader>
                <CardContent>
                    {#if $refundsQuery.isLoading}
                        <div class="flex items-center justify-center py-4">
                            <div class="animate-spin rounded-full h-6 w-6 border-b-2 border-primary"></div>
                        </div>
                    {:else if $refundsQuery.error}
                        <div class="text-center py-4 text-destructive text-sm">
                            Failed to load refunds
                        </div>
                    {:else}
                        <RefundManager 
                            refunds={$refundsQuery.data || []}
                            attendees={$attendeesQuery.data || []}
                            {workshopId}
                            on:refundProcessed={() => {
                                queryClient.invalidateQueries({ queryKey: ['workshop-refunds', workshopId] });
                                queryClient.invalidateQueries({ queryKey: ['workshop-attendees', workshopId] });
                                toast.success('Refund processed successfully');
                            }}
                        />
                    {/if}
                </CardContent>
            </Card>
        </div>
    </div>
</div>
```

### 2. Attendance Tracker Component

**File**: `src/lib/components/workshops/attendance-tracker.svelte`

```svelte
<script lang="ts">
    import { createEventDispatcher } from 'svelte';
    import { createMutation } from '@tanstack/svelte-query';
    import { Button } from '$lib/components/ui/button';
    import { Badge } from '$lib/components/ui/badge';
    import { Checkbox } from '$lib/components/ui/checkbox';
    import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '$lib/components/ui/select';
    import { Textarea } from '$lib/components/ui/textarea';
    import { toast } from 'svelte-sonner';
    
    export let attendees: any[];
    export let workshopId: string;
    
    const dispatch = createEventDispatcher();
    
    let attendanceUpdates: Record<string, {
        attendance_status: string;
        notes: string;
    }> = {};
    
    const updateAttendanceMutation = createMutation(() => ({
        mutationFn: async (updates: any[]) => {
            const response = await fetch(`/api/workshops/${workshopId}/attendance`, {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ attendance_updates: updates })
            });
            
            if (!response.ok) {
                const error = await response.json();
                throw new Error(error.error || 'Failed to update attendance');
            }
            
            return response.json();
        },
        onSuccess: () => {
            attendanceUpdates = {};
            dispatch('attendanceUpdated');
        },
        onError: (error: any) => {
            toast.error(error.message);
        }
    }));
    
    function handleStatusChange(registrationId: string, status: string) {
        attendanceUpdates[registrationId] = {
            ...attendanceUpdates[registrationId],
            attendance_status: status
        };
    }
    
    function handleNotesChange(registrationId: string, notes: string) {
        attendanceUpdates[registrationId] = {
            ...attendanceUpdates[registrationId],
            notes
        };
    }
    
    function saveAttendance() {
        const updates = Object.entries(attendanceUpdates).map(([registration_id, data]) => ({
            registration_id,
            ...data
        }));
        
        if (updates.length === 0) {
            toast.error('No changes to save');
            return;
        }
        
        $updateAttendanceMutation.mutate(updates);
    }
    
    function getStatusBadgeVariant(status: string) {
        switch (status) {
            case 'attended': return 'default';
            case 'no_show': return 'destructive';
            case 'excused': return 'secondary';
            default: return 'outline';
        }
    }
    
    function getAttendeeDisplayName(attendee: any) {
        return attendee.member_first_name 
            ? `${attendee.member_first_name} ${attendee.member_last_name}`
            : `${attendee.external_first_name} ${attendee.external_last_name}`;
    }
</script>

<div class="space-y-4">
    {#each attendees as attendee (attendee.id)}
        <div class="flex items-center justify-between p-4 border rounded-lg">
            <div class="flex-1">
                <div class="font-medium">{getAttendeeDisplayName(attendee)}</div>
                <div class="text-sm text-muted-foreground">
                    {attendee.member_email || attendee.external_email}
                </div>
                <Badge variant={getStatusBadgeVariant(attendee.attendance_status)} class="mt-1">
                    {attendee.attendance_status || 'pending'}
                </Badge>
            </div>
            
            <div class="flex items-center gap-4">
                <Select 
                    value={attendanceUpdates[attendee.id]?.attendance_status || attendee.attendance_status || 'pending'}
                    onValueChange={(value) => handleStatusChange(attendee.id, value)}
                >
                    <SelectTrigger class="w-32">
                        <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                        <SelectItem value="pending">Pending</SelectItem>
                        <SelectItem value="attended">Attended</SelectItem>
                        <SelectItem value="no_show">No Show</SelectItem>
                        <SelectItem value="excused">Excused</SelectItem>
                    </SelectContent>
                </Select>
                
                <Textarea
                    placeholder="Notes..."
                    class="w-48 h-8"
                    value={attendanceUpdates[attendee.id]?.notes || attendee.attendance_notes || ''}
                    on:input={(e) => handleNotesChange(attendee.id, e.target.value)}
                />
            </div>
        </div>
    {/each}
    
    {#if Object.keys(attendanceUpdates).length > 0}
        <div class="flex justify-end pt-4">
            <Button 
                on:click={saveAttendance}
                disabled={$updateAttendanceMutation.isPending}
            >
                {#if $updateAttendanceMutation.isPending}
                    Saving...
                {:else}
                    Save Changes
                {/if}
            </Button>
        </div>
    {/if}
</div>
```

### 3. Refund Manager Component

**File**: `src/lib/components/workshops/refund-manager.svelte`

```svelte
<script lang="ts">
    import { createEventDispatcher } from 'svelte';
    import { createMutation } from '@tanstack/svelte-query';
    import { Button } from '$lib/components/ui/button';
    import { Badge } from '$lib/components/ui/badge';
    import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogTrigger } from '$lib/components/ui/dialog';
    import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '$lib/components/ui/select';
    import { Textarea } from '$lib/components/ui/textarea';
    import { Label } from '$lib/components/ui/label';
    import { toast } from 'svelte-sonner';
    import { formatCurrency } from '$lib/utils';
    
    export let refunds: any[];
    export let attendees: any[];
    export let workshopId: string;
    
    const dispatch = createEventDispatcher();
    
    let selectedRegistrationId = '';
    let refundReason = '';
    let showRefundDialog = false;
    
    const processRefundMutation = createMutation(() => ({
        mutationFn: async (data: { registration_id: string; reason: string }) => {
            const response = await fetch(`/api/workshops/${workshopId}/refunds`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(data)
            });
            
            if (!response.ok) {
                const error = await response.json();
                throw new Error(error.error || 'Failed to process refund');
            }
            
            return response.json();
        },
        onSuccess: () => {
            showRefundDialog = false;
            selectedRegistrationId = '';
            refundReason = '';
            dispatch('refundProcessed');
        },
        onError: (error: any) => {
            toast.error(error.message);
        }
    }));
    
    function processRefund() {
        if (!selectedRegistrationId || !refundReason.trim()) {
            toast.error('Please select an attendee and provide a reason');
            return;
        }
        
        $processRefundMutation.mutate({
            registration_id: selectedRegistrationId,
            reason: refundReason.trim()
        });
    }
    
    function getStatusBadgeVariant(status: string) {
        switch (status) {
            case 'completed': return 'default';
            case 'processing': return 'secondary';
            case 'failed': return 'destructive';
            case 'cancelled': return 'outline';
            default: return 'secondary';
        }
    }
    
    function getAttendeeDisplayName(attendee: any) {
        return attendee.member_first_name 
            ? `${attendee.member_first_name} ${attendee.member_last_name}`
            : `${attendee.external_first_name} ${attendee.external_last_name}`;
    }
    
    // Filter out attendees who already have refunds
    $: eligibleAttendees = attendees.filter(attendee => 
        !refunds.some(refund => refund.registration_id === attendee.id)
    );
</script>

<div class="space-y-4">
    <!-- Process New Refund -->
    <Dialog bind:open={showRefundDialog}>
        <DialogTrigger asChild>
            <Button variant="outline" class="w-full">Process Refund</Button>
        </DialogTrigger>
        <DialogContent>
            <DialogHeader>
                <DialogTitle>Process Refund</DialogTitle>
            </DialogHeader>
            
            <div class="space-y-4">
                <div>
                    <Label for="attendee-select">Select Attendee</Label>
                    <Select bind:value={selectedRegistrationId}>
                        <SelectTrigger>
                            <SelectValue placeholder="Choose attendee..." />
                        </SelectTrigger>
                        <SelectContent>
                            {#each eligibleAttendees as attendee (attendee.id)}
                                <SelectItem value={attendee.id}>
                                    {getAttendeeDisplayName(attendee)}
                                </SelectItem>
                            {/each}
                        </SelectContent>
                    </Select>
                </div>
                
                <div>
                    <Label for="refund-reason">Reason for Refund</Label>
                    <Textarea
                        id="refund-reason"
                        placeholder="Enter reason for refund..."
                        bind:value={refundReason}
                        rows={3}
                    />
                </div>
                
                <div class="flex justify-end gap-2">
                    <Button variant="outline" on:click={() => showRefundDialog = false}>
                        Cancel
                    </Button>
                    <Button 
                        on:click={processRefund}
                        disabled={$processRefundMutation.isPending}
                    >
                        {#if $processRefundMutation.isPending}
                            Processing...
                        {:else}
                            Process Refund
                        {/if}
                    </Button>
                </div>
            </div>
        </DialogContent>
    </Dialog>
    
    <!-- Existing Refunds -->
    {#if refunds.length > 0}
        <div class="space-y-2">
            <h4 class="font-medium">Existing Refunds</h4>
            {#each refunds as refund (refund.id)}
                {@const attendee = attendees.find(a => a.id === refund.registration_id)}
                <div class="p-3 border rounded-lg">
                    <div class="flex items-center justify-between">
                        <div>
                            <div class="font-medium text-sm">
                                {attendee ? getAttendeeDisplayName(attendee) : 'Unknown'}
                            </div>
                            <div class="text-xs text-muted-foreground">
                                {formatCurrency(refund.refund_amount / 100)}
                            </div>
                        </div>
                        <Badge variant={getStatusBadgeVariant(refund.status)}>
                            {refund.status}
                        </Badge>
                    </div>
                    {#if refund.refund_reason}
                        <div class="text-xs text-muted-foreground mt-1">
                            {refund.refund_reason}
                        </div>
                    {/if}
                </div>
            {/each}
        </div>
    {:else}
        <div class="text-center py-4 text-muted-foreground text-sm">
            No refunds processed yet
        </div>
    {/if}
</div>
```

## Test Specifications

### 1. E2E Tests for Refund Management

**File**: `e2e/refund-management.spec.ts`

```typescript
import { test, expect } from '@playwright/test';
import { setupFunctions } from './setupFunctions';
import { makeAuthenticatedRequest } from './setupFunctions';

test.describe('Refund Management', () => {
    let workshopId: string;
    let registrationId: string;
    
    test.beforeEach(async ({ page }) => {
        await setupFunctions.loginAsAdmin(page);
        
        // Create a test workshop
        const timestamp = Date.now();
        const workshopResponse = await makeAuthenticatedRequest(page, '/api/workshops', {
            method: 'POST',
            data: {
                title: `Test Workshop ${timestamp}`,
                description: 'Test workshop for refund testing',
                location: 'Test Location',
                workshop_date: new Date(Date.now() + 7 * 24 * 60 * 60 * 1000), // 7 days from now
                workshop_end_date: new Date(Date.now() + 7 * 24 * 60 * 60 * 1000 + 2 * 60 * 60 * 1000), // 2 hours later
                max_capacity: 10,
                price_member: 25.00,
                price_non_member: 35.00,
                is_public: true,
                refund_deadline_days: 3
            }
        });
        
        expect(workshopResponse.ok).toBeTruthy();
        const workshopData = await workshopResponse.json();
        workshopId = workshopData.workshop.id;
        
        // Create a test registration (would normally be done through registration flow)
        // For testing purposes, we'll create it directly
        const registrationResponse = await makeAuthenticatedRequest(page, `/api/workshops/${workshopId}/register`, {
            method: 'POST',
            data: {
                member_user_id: 'test-user-id',
                amount_paid: 2500 // 25.00 in cents
            }
        });
        
        const registrationData = await registrationResponse.json();
        registrationId = registrationData.registration.id;
    });
    
    test('should process refund successfully', async ({ page }) => {
        const refundResponse = await makeAuthenticatedRequest(page, `/api/workshops/${workshopId}/refunds`, {
            method: 'POST',
            data: {
                registration_id: registrationId,
                reason: 'Test refund reason'
            }
        });
        
        expect(refundResponse.ok).toBeTruthy();
        const refundData = await refundResponse.json();
        
        expect(refundData.success).toBe(true);
        expect(refundData.refund).toBeDefined();
        expect(refundData.refund.registration_id).toBe(registrationId);
        expect(refundData.refund.refund_reason).toBe('Test refund reason');
        expect(refundData.refund.status).toBe('pending');
    });
    
    test('should not allow duplicate refunds', async ({ page }) => {
        // Process first refund
        await makeAuthenticatedRequest(page, `/api/workshops/${workshopId}/refunds`, {
            method: 'POST',
            data: {
                registration_id: registrationId,
                reason: 'First refund'
            }
        });
        
        // Attempt second refund
        const secondRefundResponse = await makeAuthenticatedRequest(page, `/api/workshops/${workshopId}/refunds`, {
            method: 'POST',
            data: {
                registration_id: registrationId,
                reason: 'Second refund attempt'
            }
        });
        
        expect(secondRefundResponse.ok).toBeFalsy();
        const errorData = await secondRefundResponse.json();
        expect(errorData.success).toBe(false);
        expect(errorData.error).toContain('already requested');
    });
    
    test('should respect refund deadline', async ({ page }) => {
        // Create workshop with past refund deadline
        const pastWorkshopResponse = await makeAuthenticatedRequest(page, '/api/workshops', {
            method: 'POST',
            data: {
                title: `Past Deadline Workshop ${Date.now()}`,
                description: 'Workshop with past refund deadline',
                location: 'Test Location',
                workshop_date: new Date(Date.now() + 24 * 60 * 60 * 1000), // Tomorrow
                workshop_end_date: new Date(Date.now() + 24 * 60 * 60 * 1000 + 2 * 60 * 60 * 1000),
                max_capacity: 10,
                price_member: 25.00,
                price_non_member: 35.00,
                is_public: true,
                refund_deadline_days: 7 // 7 days before (already passed)
            }
        });
        
        const pastWorkshopData = await pastWorkshopResponse.json();
        const pastWorkshopId = pastWorkshopData.workshop.id;
        
        // Create registration for past deadline workshop
        const pastRegistrationResponse = await makeAuthenticatedRequest(page, `/api/workshops/${pastWorkshopId}/register`, {
            method: 'POST',
            data: {
                member_user_id: 'test-user-id',
                amount_paid: 2500
            }
        });
        
        const pastRegistrationData = await pastRegistrationResponse.json();
        const pastRegistrationId = pastRegistrationData.registration.id;
        
        // Attempt refund
        const refundResponse = await makeAuthenticatedRequest(page, `/api/workshops/${pastWorkshopId}/refunds`, {
            method: 'POST',
            data: {
                registration_id: pastRegistrationId,
                reason: 'Late refund attempt'
            }
        });
        
        expect(refundResponse.ok).toBeFalsy();
        const errorData = await refundResponse.json();
        expect(errorData.success).toBe(false);
        expect(errorData.error).toContain('deadline');
    });
});
```

### 2. E2E Tests for Attendance Management

**File**: `e2e/attendance-management.spec.ts`

```typescript
import { test, expect } from '@playwright/test';
import { setupFunctions } from './setupFunctions';
import { makeAuthenticatedRequest } from './setupFunctions';

test.describe('Attendance Management', () => {
    let workshopId: string;
    let registrationIds: string[] = [];
    
    test.beforeEach(async ({ page }) => {
        await setupFunctions.loginAsAdmin(page);
        
        // Create test workshop
        const timestamp = Date.now();
        const workshopResponse = await makeAuthenticatedRequest(page, '/api/workshops', {
            method: 'POST',
            data: {
                title: `Attendance Test Workshop ${timestamp}`,
                description: 'Test workshop for attendance tracking',
                location: 'Test Location',
                workshop_date: new Date(Date.now() + 7 * 24 * 60 * 60 * 1000),
                workshop_end_date: new Date(Date.now() + 7 * 24 * 60 * 60 * 1000 + 2 * 60 * 60 * 1000),
                max_capacity: 10,
                price_member: 25.00,
                price_non_member: 35.00,
                is_public: true,
                refund_deadline_days: 3
            }
        });
        
        const workshopData = await workshopResponse.json();
        workshopId = workshopData.workshop.id;
        
        // Create multiple test registrations
        for (let i = 0; i < 3; i++) {
            const registrationResponse = await makeAuthenticatedRequest(page, `/api/workshops/${workshopId}/register`, {
                method: 'POST',
                data: {
                    member_user_id: `test-user-${i}`,
                    amount_paid: 2500
                }
            });
            
            const registrationData = await registrationResponse.json();
            registrationIds.push(registrationData.registration.id);
        }
    });
    
    test('should fetch workshop attendance', async ({ page }) => {
        const attendanceResponse = await makeAuthenticatedRequest(page, `/api/workshops/${workshopId}/attendance`, {
            method: 'GET'
        });
        
        expect(attendanceResponse.ok).toBeTruthy();
        const attendanceData = await attendanceResponse.json();
        
        expect(attendanceData.success).toBe(true);
        expect(attendanceData.attendance).toBeDefined();
        expect(attendanceData.attendance.length).toBe(3);
        
        // Check default attendance status
        attendanceData.attendance.forEach((attendee: any) => {
            expect(attendee.attendance_status).toBe('pending');
        });
    });
    
    test('should update attendance status', async ({ page }) => {
        const attendanceUpdates = [
            {
                registration_id: registrationIds[0],
                attendance_status: 'attended',
                notes: 'Present and participated'
            },
            {
                registration_id: registrationIds[1],
                attendance_status: 'no_show'
            },
            {
                registration_id: registrationIds[2],
                attendance_status: 'excused',
                notes: 'Family emergency'
            }
        ];
        
        const updateResponse = await makeAuthenticatedRequest(page, `/api/workshops/${workshopId}/attendance`, {
            method: 'PUT',
            data: { attendance_updates: attendanceUpdates }
        });
        
        expect(updateResponse.ok).toBeTruthy();
        const updateData = await updateResponse.json();
        
        expect(updateData.success).toBe(true);
        expect(updateData.registrations).toBeDefined();
        expect(updateData.registrations.length).toBe(3);
        
        // Verify updates
        const updatedRegistrations = updateData.registrations;
        expect(updatedRegistrations.find((r: any) => r.id === registrationIds[0]).attendance_status).toBe('attended');
        expect(updatedRegistrations.find((r: any) => r.id === registrationIds[1]).attendance_status).toBe('no_show');
        expect(updatedRegistrations.find((r: any) => r.id === registrationIds[2]).attendance_status).toBe('excused');
    });
    
    test('should validate attendance update data', async ({ page }) => {
        const invalidUpdates = [
            {
                registration_id: 'invalid-uuid',
                attendance_status: 'attended'
            }
        ];
        
        const updateResponse = await makeAuthenticatedRequest(page, `/api/workshops/${workshopId}/attendance`, {
            method: 'PUT',
            data: { attendance_updates: invalidUpdates }
        });
        
        expect(updateResponse.ok).toBeFalsy();
        const errorData = await updateResponse.json();
        expect(errorData.success).toBe(false);
        expect(errorData.issues).toBeDefined();
    });
});
```

### 3. Unit Tests for Business Logic

**File**: `src/lib/server/refunds.test.ts`

```typescript
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { processRefund, getWorkshopRefunds } from './refunds';

// Mock dependencies
vi.mock('./kysely');
vi.mock('./stripe');

describe('Refund Management', () => {
    beforeEach(() => {
        vi.clearAllMocks();
    });
    
    it('should validate refund eligibility', async () => {
        // Test implementation would mock database calls
        // and verify business logic
    });
    
    it('should calculate correct refund amount', async () => {
        // Test refund amount calculation logic
    });
    
    it('should handle Stripe integration errors', async () => {
        // Test error handling for Stripe API failures
    });
});
```

## Security Considerations

### 1. RLS Policies
- All refund and attendance data protected by RLS
- Committee members can manage all data
- Members can only view their own refunds
- External users have no direct access

### 2. Input Validation
- All API inputs validated with Valibot schemas
- UUID validation for all ID parameters
- String length limits for text fields
- Enum validation for status fields

### 3. Authorization
- All endpoints require authentication
- Role-based access control using WORKSHOP_ROLES
- Session validation on every request

### 4. Stripe Integration
- Webhook signature verification
- Secure API key handling
- Error handling for payment failures

## Performance Optimizations

### 1. Database Indexes
- Indexes on frequently queried fields
- Composite indexes for complex queries
- Foreign key indexes for joins

### 2. Frontend Optimizations
- TanStack Query for caching and background updates
- Optimistic updates for better UX
- Lazy loading of components
- Debounced search and filters

### 3. API Optimizations
- Batch operations where possible
- Efficient database queries
- Proper error handling and logging

## Deployment Considerations

### 1. Database Migration
- Run migration before deploying code changes
- Test migration on staging environment
- Backup database before production migration

### 2. Environment Variables
- Ensure Stripe keys are properly configured
- Verify database connection strings
- Check Sentry configuration

### 3. Monitoring
- Monitor refund processing success rates
- Track API response times
- Set up alerts for failed refunds

<function_calls>
<invoke name="todowrite">
<parameter name="todos">[{"content": "Analyze existing database schema and patterns", "status": "completed", "priority": "high", "id": "1"}, {"content": "Design database migrations for refunds and attendance", "status": "completed", "priority": "high", "id": "2"}, {"content": "Design API endpoints following existing patterns", "status": "completed", "priority": "high", "id": "3"}, {"content": "Design frontend components and pages", "status": "completed", "priority": "medium", "id": "4"}, {"content": "Design validation schemas and business logic", "status": "completed", "priority": "medium", "id": "5"}, {"content": "Design test specifications", "status": "completed", "priority": "medium", "id": "6"}, {"content": "Create comprehensive low-level design document", "status": "completed", "priority": "high", "id": "7"}]
