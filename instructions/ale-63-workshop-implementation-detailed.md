# Beginner's Workshop Feature - Detailed Implementation Guide

> **Status:** Draft  
> **Updated:** 2025-07-01  
> **Scope:** Pre-workshop onboarding + self-service check-in improvements

## Overview

This document provides detailed technical implementation specifications for the improved workshop check-in flow, focusing on:

1. **Pre-workshop digital onboarding** (2-3 days before workshop)
2. **Self-service check-in** via workshop-wide QR code  
3. **Real-time attendance tracking** for administrators

## Key Changes from Original Design

### Previous Flow (Individual QR Codes)
- ❌ Admin scans each attendee's unique QR code
- ❌ Admin manually processes insurance/consent forms
- ❌ High friction for admin on workshop day

### New Flow (Self-Service)
- ✅ Attendees complete pre-workshop onboarding online
- ✅ Single QR code per workshop for self-check-in
- ✅ Attendees identify themselves via email selection
- ✅ Real-time admin dashboard shows attendance status

---

## Database Schema Updates

### Workshop Attendees Table Changes

```sql
-- Add new columns to existing workshop_attendees table
ALTER TABLE workshop_attendees ADD COLUMN IF NOT EXISTS onboarding_token text;
ALTER TABLE workshop_attendees ADD COLUMN IF NOT EXISTS onboarding_completed_at timestamptz;

-- Update status enum to include pre_checked
ALTER TYPE workshop_attendee_status ADD VALUE IF NOT EXISTS 'pre_checked';

-- Status flow: invited → confirmed → pre_checked → attended
```

### Status Transitions

```
invited (payment link sent)
    ↓ (payment successful)
confirmed (payment received)
    ↓ (pre-workshop onboarding completed)
pre_checked (insurance + consent completed)
    ↓ (workshop day check-in)
attended (physically present)
```

---

## Backend Implementation

### 1. Pre-Workshop Onboarding

#### Edge Function: `workshop_onboarding`

**File:** `supabase/functions/workshop_onboarding/index.ts`

```typescript
// Scheduled cron: daily at 9 AM
// Triggers 2 days before workshop date

export async function handler() {
  import dayjs from 'dayjs';
  import { executeWithRLS } from '../../../src/lib/server/kysely.js';
  
  const twoDaysFromNow = dayjs().add(2, 'day');
  const twoDaysFromNowEnd = twoDaysFromNow.add(1, 'day');
  
  // Find workshops happening in 2 days with confirmed attendees using Kysely
  const workshops = await executeWithRLS(async (db) => {
    return await db
      .selectFrom('workshops')
      .innerJoin('workshop_attendees', 'workshops.id', 'workshop_attendees.workshop_id')
      .innerJoin('user_profiles', 'workshop_attendees.user_profile_id', 'user_profiles.id')
      .select([
        'workshops.id',
        'workshops.workshop_date',
        'workshops.location',
        'workshop_attendees.id as attendee_id',
        'workshop_attendees.onboarding_token',
        'workshop_attendees.onboarding_completed_at',
        'user_profiles.email',
        'user_profiles.first_name',
        'user_profiles.last_name'
      ])
      .where('workshops.status', '=', 'published')
      .where('workshop_attendees.status', '=', 'confirmed')
      .where('workshop_attendees.onboarding_completed_at', 'is', null)
      .where('workshops.workshop_date', '>=', twoDaysFromNow.format('YYYY-MM-DD'))
      .where('workshops.workshop_date', '<', twoDaysFromNowEnd.format('YYYY-MM-DD'))
      .execute();
  });

  for (const row of workshops) {
    // Generate onboarding token if not exists
    if (!row.onboarding_token) {
      const token = crypto.randomUUID();
      await executeWithRLS(async (db) => {
        return await db
          .updateTable('workshop_attendees')
          .set({ onboarding_token: token })
          .where('id', '=', row.attendee_id)
          .execute();
      });
      row.onboarding_token = token;
    }

    // Send onboarding email (TODO: implement email sending)
    await sendOnboardingEmail({
      email: row.email,
      firstName: row.first_name,
      workshopDate: row.workshop_date,
      location: row.location,
      onboardingUrl: `${SITE_URL}/workshop/onboarding/${row.onboarding_token}`,
      checkinQrUrl: `${SITE_URL}/workshop/checkin/${row.id}`
    });
  }
}
```

#### API Endpoint: Onboarding Form Submission

**File:** `src/routes/api/workshop/onboarding/+server.ts`

```typescript
export async function POST({ request }) {
  import dayjs from 'dayjs';
  import { executeWithRLS } from '$lib/server/kysely.js';
  
  const { token, insuranceConfirmed, mediaConsent, signature } = await request.json();
  
  // Validate token and get attendee using Kysely
  const attendee = await executeWithRLS(async (db) => {
    const result = await db
      .selectFrom('workshop_attendees')
      .selectAll()
      .where('onboarding_token', '=', token)
      .executeTakeFirst();
    return result;
  });

  if (!attendee) {
    return json({ error: 'Invalid token' }, { status: 400 });
  }

  // Update attendee with onboarding completion using Kysely
  const now = dayjs().toISOString();
  await executeWithRLS(async (db) => {
    return await db
      .updateTable('workshop_attendees')
      .set({
        onboarding_completed_at: now,
        insurance_ok_at: insuranceConfirmed ? now : null,
        consent_media_at: mediaConsent ? now : null,
        signature_url: signature || null,
        status: 'pre_checked'
      })
      .where('id', '=', attendee.id)
      .execute();
  });

  return json({ success: true });
}
```

### 2. Workshop Check-In

#### API Endpoint: Workshop Check-In

**File:** `src/routes/api/workshop/checkin/+server.ts`

```typescript
export async function POST({ request }) {
  import dayjs from 'dayjs';
  import { executeWithRLS } from '$lib/server/kysely.js';
  
  const { workshopId, attendeeEmail } = await request.json();
  
  // Find attendee by email and workshop using Kysely
  const attendee = await executeWithRLS(async (db) => {
    return await db
      .selectFrom('workshop_attendees')
      .innerJoin('user_profiles', 'workshop_attendees.user_profile_id', 'user_profiles.id')
      .select([
        'workshop_attendees.id',
        'workshop_attendees.status',
        'user_profiles.email',
        'user_profiles.first_name',
        'user_profiles.last_name'
      ])
      .where('workshop_attendees.workshop_id', '=', workshopId)
      .where('user_profiles.email', '=', attendeeEmail)
      .where('workshop_attendees.status', 'in', ['confirmed', 'pre_checked'])
      .executeTakeFirst();
  });

  if (!attendee) {
    return json({ error: 'Attendee not found or not eligible for check-in' }, { status: 404 });
  }

  // Mark as attended using Kysely
  await executeWithRLS(async (db) => {
    return await db
      .updateTable('workshop_attendees')
      .set({
        checked_in_at: dayjs().toISOString(),
        status: 'attended'
      })
      .where('id', '=', attendee.id)
      .execute();
  });

  return json({ 
    success: true, 
    attendee: {
      email: attendee.email,
      first_name: attendee.first_name,
      last_name: attendee.last_name
    }
  });
}
```

**Note:** The check-in data can be fetched directly from the frontend using Supabase client queries. No additional API endpoint needed since this is just read operations that should respect RLS policies.

---

## Frontend Implementation

**Important Notes for Implementation:**
1. **Check existing schemas:** Review files in `@src/lib/schemas/` folder for reusable validation schemas before creating new ones
2. **Use shadcn-svelte components:** Utilize existing UI components from the shadcn-svelte library throughout the frontend

### 1. Pre-Workshop Onboarding Page

**File:** `src/routes/workshop/onboarding/[token]/+page.svelte`

```svelte
<script lang="ts">
  import { page } from '$app/stores';
  import { superForm } from 'sveltekit-superforms';
  import { valibot } from 'sveltekit-superforms/adapters';
  import { onboardingSchema } from '$lib/schemas/workshop.js';
  
  let { data } = $props();
  
  const { form, errors, enhance, submitting } = superForm(data.form, {
    validators: valibot(onboardingSchema),
    onUpdated: ({ form }) => {
      if (form.valid) {
        // Show success message
      }
    }
  });
</script>

<div class="max-w-md mx-auto p-6">
  <h1>Pre-Workshop Requirements</h1>
  <p>Please complete these items before attending the workshop:</p>
  
  <form method="POST" use:enhance>
    <label class="flex items-start space-x-2 mb-4">
      <input 
        type="checkbox" 
        name="insuranceConfirmed"
        bind:checked={$form.insuranceConfirmed}
        required 
        class="mt-1"
      />
      <span>
        I confirm I have completed the 
        <a href="https://hemaireland.com/insurance" target="_blank" class="text-blue-600 underline">
          HEMA Ireland Insurance form
        </a> *
      </span>
    </label>
    {#if $errors.insuranceConfirmed}
      <p class="text-red-600 text-sm mb-4">{$errors.insuranceConfirmed}</p>
    {/if}
    
    <label class="flex items-start space-x-2 mb-4">
      <input 
        type="checkbox" 
        name="mediaConsent"
        bind:checked={$form.mediaConsent}
        class="mt-1"
      />
      <span>I consent to photography/video for social media (optional)</span>
    </label>
    
    <!-- Optional digital signature component -->
    <div class="mb-4">
      <label for="signature" class="block text-sm font-medium mb-2">
        Digital Signature (optional)
      </label>
      <input 
        type="text" 
        name="signature"
        id="signature"
        bind:value={$form.signature}
        placeholder="Type your full name"
        class="w-full p-2 border rounded"
      />
    </div>
    
    <button 
      type="submit" 
      disabled={!$form.insuranceConfirmed || $submitting}
      class="w-full bg-blue-600 text-white p-3 rounded disabled:opacity-50"
    >
      {$submitting ? 'Saving...' : 'Complete Pre-Workshop Setup'}
    </button>
  </form>
</div>
```

**Schema:** `src/lib/schemas/workshop.ts`

```typescript
import * as v from 'valibot';

export const onboardingSchema = v.object({
  insuranceConfirmed: v.pipe(
    v.boolean(),
    v.check(val => val === true, 'Insurance form confirmation is required')
  ),
  mediaConsent: v.optional(v.boolean()),
  signature: v.optional(v.string())
});

export const checkinSchema = v.object({
  workshopId: v.pipe(v.string(), v.uuid()),
  attendeeEmail: v.pipe(v.string(), v.email())
});
```

### 2. Workshop Check-In Page

**File:** `src/routes/workshop/checkin/[workshopId]/+page.svelte`

```svelte
<script lang="ts">
  import { page } from '$app/stores';
  import { createQuery, createMutation } from '@tanstack/svelte-query';
  
  let selectedEmail = $state('');
  
  const workshopQuery = createQuery({
    queryKey: ['workshop-checkin', $page.params.workshopId],
    queryFn: async () => {
      // Use Supabase client directly for read operations with RLS
      const { data: workshop } = await supabase
        .from('workshops')
        .select('id, workshop_date, location')
        .eq('id', $page.params.workshopId)
        .single();
        
      const { data: attendees } = await supabase
        .from('workshop_attendees')
        .select(`
          status, checked_in_at,
          user_profiles(email, first_name, last_name)
        `)
        .eq('workshop_id', $page.params.workshopId)
        .in('status', ['confirmed', 'pre_checked', 'attended']);
        
      return {
        workshop,
        attendees: attendees?.map(a => ({
          email: a.user_profiles.email,
          name: `${a.user_profiles.first_name} ${a.user_profiles.last_name}`,
          status: a.status,
          checkedIn: a.status === 'attended'
        })) || []
      };
    }
  });
  
  const checkinMutation = createMutation({
    mutationFn: async (email) => {
      const res = await fetch('/api/workshop/checkin', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          workshopId: $page.params.workshopId,
          attendeeEmail: email
        })
      });
      return res.json();
    },
    onSuccess: () => {
      // Refetch workshop data to update UI
      workshopQuery.refetch();
      selectedEmail = '';
    }
  });
  
  function handleCheckin() {
    if (!selectedEmail) return;
    $checkinMutation.mutate(selectedEmail);
  }
</script>

{#if $workshopQuery.data}
  <div class="max-w-md mx-auto p-6">
    <h1>Workshop Check-In</h1>
    <p>{$workshopQuery.data.workshop.location}</p>
    <p>{new Date($workshopQuery.data.workshop.date).toLocaleDateString()}</p>
    
    <div class="mt-6">
      <label for="attendee-select">Select your name:</label>
      <select 
        id="attendee-select"
        bind:value={selectedEmail}
        class="w-full mt-2 p-2 border rounded"
      >
        <option value="">-- Choose your name --</option>
        {#each $workshopQuery.data.attendees.filter(a => !a.checkedIn) as attendee}
          <option value={attendee.email}>
            {attendee.name} 
            {attendee.status === 'pre_checked' ? '✓' : '⚠️'}
          </option>
        {/each}
      </select>
    </div>
    
    <button 
      onclick={handleCheckin}
      disabled={!selectedEmail || $checkinMutation.isPending}
      class="w-full mt-4 bg-blue-600 text-white p-3 rounded"
    >
      Check In
    </button>
    
    <!-- Show success message for completed check-ins -->
    {#if $checkinMutation.isSuccess}
      <div class="mt-4 p-4 bg-green-100 text-green-800 rounded">
        Successfully checked in! Welcome to the workshop.
      </div>
    {/if}
  </div>
{/if}
```

### 3. Enhanced Existing Attendee List with Real-Time Updates

**Enhancement to existing attendee list component:**

```svelte
<!-- Add to existing workshop attendee table component -->
<script lang="ts">
  import { createQuery } from '@tanstack/svelte-query';
  
  // Existing attendee list query with real-time updates, use the supabase realtime feature
  
  // Check if workshop is happening today
  const isWorkshopToday = $derived(() => {
    if (!$attendeesQuery.data?.workshop?.date) return false;
    const today = dayjs().format('YYYY-MM-DD');
    const workshopDate = dayjs($attendeesQuery.data.workshop.date).format('YYYY-MM-DD');
    return today === workshopDate;
  });
</script>

<!-- Existing attendee table with enhanced status indicators -->
<div class="attendee-list">
  {#if isWorkshopToday()}
    <div class="mb-4 p-3 bg-blue-50 border border-blue-200 rounded">
      <p class="text-blue-800">
        🔄 Live attendance tracking active - updates every 5 seconds
      </p>
    </div>
  {/if}
  
  <!-- Existing table structure with enhanced status column -->
  <table class="w-full">
    <thead>
      <tr>
        <th>Name</th>
        <th>Email</th>
        <th>Status</th>
        <th>Pre-Workshop</th>
        <th>Check-In Time</th>
      </tr>
    </thead>
    <tbody>
      {#each $attendeesQuery.data?.attendees || [] as attendee}
        <tr class="border-b">
          <td>{attendee.name}</td>
          <td>{attendee.email}</td>
          <td>
            <span class="px-2 py-1 rounded text-sm" 
                  class:bg-gray-100={attendee.status === 'invited'}
                  class:bg-blue-100={attendee.status === 'confirmed'}
                  class:bg-green-100={attendee.status === 'pre_checked'}
                  class:bg-purple-100={attendee.status === 'attended'}
                  class:bg-red-100={attendee.status === 'no_show'}>
              {attendee.status}
              {#if attendee.status === 'attended'}
                ✅
              {:else if attendee.status === 'pre_checked'}
                📋✓
              {:else if attendee.status === 'confirmed'}
                💳
              {/if}
            </span>
          </td>
          <td class="text-center">
            {#if attendee.insurance_ok_at}
              <span title="Insurance confirmed">🛡️</span>
            {/if}
            {#if attendee.consent_media_at}
              <span title="Media consent given">📸</span>
            {/if}
            {#if attendee.signature_url}
              <span title="Signature provided">✍️</span>
            {/if}
          </td>
          <td>
            {#if attendee.checked_in_at}
              {dayjs(attendee.checked_in_at).format('HH:mm')}
            {:else}
              -
            {/if}
          </td>
        </tr>
      {/each}
    </tbody>
  </table>
</div>
```

---

## Email Implementation

**Note:** Email template implementation via Loops.so will be handled separately. For now, the edge function includes placeholder `sendOnboardingEmail()` calls that can be implemented later.

---

## QR Code Implementation

### Workshop-Wide QR Code Generation

```typescript
// Generate QR code for workshop check-in page
import QRCode from 'qrcode';

export async function generateWorkshopQR(workshopId: string) {
  const checkinUrl = `${SITE_URL}/workshop/checkin/${workshopId}`;
  const qrCodeSvg = await QRCode.toString(checkinUrl, { 
    type: 'svg',
    margin: 2,
    width: 200
  });
  
  return {
    url: checkinUrl,
    svg: qrCodeSvg
  };
}
```

### Display QR Code Component

```svelte
<!-- QR Code Display for Workshop Entrance -->
<script lang="ts">
  let { workshopId } = $props();
  
  // Fetch QR code data
</script>

<div class="text-center p-8 bg-white border-2 border-gray-300 rounded-lg">
  <h2 class="text-xl font-bold mb-4">Workshop Check-In</h2>
  <div class="qr-code mb-4">
    <!-- QR Code SVG here -->
  </div>
  <p class="text-sm text-gray-600">
    Scan to check in to today's workshop
  </p>
  <p class="text-xs text-gray-500 mt-2">
    Or visit: dhc-dashboard.app/workshop/checkin/{workshopId}
  </p>
</div>
```

---

## Implementation Timeline

### Phase 1: Backend Foundation (0.5 days)
- [ ] Update database schema with onboarding fields
- [ ] Create onboarding API endpoints
- [ ] Create check-in API endpoints

### Phase 2: Frontend Pages (0.5 days)
- [ ] Build onboarding form page
- [ ] Build self-service check-in page
- [ ] Build admin attendance dashboard

### Phase 3: Email Integration (0.25 days)
- [ ] Create onboarding email template in Loops
- [ ] Update workshop_onboarding edge function
- [ ] Test email flow

### Phase 4: QR Code & Polish (0.25 days)
- [ ] Implement QR code generation
- [ ] Create printable QR code display
- [ ] Add real-time updates to admin dashboard

**Total: 1.5 dev-days**

---

## Testing Checklist

### Pre-Workshop Flow
- [ ] Onboarding email sent 2 days before workshop
- [ ] Onboarding form validates required fields
- [ ] Status updates to `pre_checked` after completion
- [ ] Invalid tokens handled gracefully

### Workshop Day Flow
- [ ] QR code displays correctly and links to check-in page
- [ ] Check-in page loads workshop data
- [ ] Attendee selection works (confirmed + pre_checked attendees)
- [ ] Check-in updates status to `attended`
- [ ] Admin dashboard shows real-time updates

### Edge Cases
- [ ] Workshop doesn't exist
- [ ] Attendee already checked in
- [ ] Attendee not eligible for check-in
- [ ] Network failures handled gracefully

---

## Security Considerations

1. **Token Validation:** Onboarding tokens should be cryptographically secure UUIDs
2. **Rate Limiting:** Check-in endpoints should be rate limited
3. **Input Validation:** All form inputs validated server-side
4. **RLS Policies:** Ensure attendees can only access their own data
5. **HTTPS Only:** All workshop-related pages require HTTPS

---

## Future Enhancements

1. **Offline Support:** Service worker for check-in page
2. **SMS Notifications:** Alternative to email for onboarding
3. **Photo Capture:** Take attendee photos during check-in
4. **Analytics Dashboard:** Workshop attendance patterns over time
5. **Integration:** Calendar invites for confirmed attendees
