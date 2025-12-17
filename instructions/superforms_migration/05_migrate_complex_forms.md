# Step 5: Migrate Complex Forms (Invite Drawer, Workshop Form, Signup Flow)

## Objective

Migrate the most complex forms that use advanced superforms features:
- Array fields (bulk invites)
- SPA mode (client-only forms)
- Date handling with proxies
- Multi-step forms
- Dynamic validation

## MCP Server Available

**IMPORTANT**: You have access to the Svelte MCP server. Use it to look up:
- SvelteKit Remote Functions array field patterns
- `field.pushValue()` and `field.removeValue()` for arrays
- Client-side only form patterns
- Date field handling

## Forms to Migrate

1. `src/routes/dashboard/members/invite-drawer.svelte` - Bulk invite with array fields
2. `src/lib/components/workshop-form.svelte` - Complex date handling, shared component
3. `src/routes/(public)/members/signup/[invitationId]/confirm-invitation.svelte`
4. `src/routes/(public)/members/signup/[invitationId]/payment-form.svelte`

---

## 1. Invite Drawer (Array Fields + SPA Mode)

### Current Implementation

The invite drawer uses:
- Two forms: single invite form and bulk invite form
- `SPA: true` mode (client-only, no server actions)
- Array field for `invites[]`
- `validateForm()` for manual validation
- `setMessage()` for success/error messages

```svelte
<script lang="ts">
  const form = superForm(defaults(valibot(adminInviteSchema)), {
    validators: valibotClient(adminInviteSchema),
    SPA: true,
    validationMethod: 'oninput'
  });
  
  const bulkInviteForm = superForm(defaults(valibot(bulkInviteSchema)), {
    SPA: true,
    dataType: 'json',
    validators: valibotClient(bulkInviteSchema),
    async onUpdate({ form }) {
      // Call edge function
      const response = await supabase.functions.invoke('bulk_invite', {
        body: { invites: form.data.invites }
      });
      // Handle response
    }
  });
</script>
```

### New Implementation

For SPA-mode forms that call APIs directly, Remote Functions still work but you handle submission differently.

Create `src/routes/dashboard/members/data.remote.ts`:

```typescript
import { form, getRequestEvent } from '$app/server';
import { adminInviteSchema, bulkInviteSchema } from '$lib/schemas/adminInvite';

/**
 * Single invite validation (for adding to bulk list)
 * This doesn't submit to server - just validates
 */
export const validateSingleInvite = form(
  adminInviteSchema,
  async (data) => {
    // This form is used for validation only
    // Return the validated data
    return { invite: data };
  }
);

/**
 * Bulk invite submission
 */
export const submitBulkInvites = form(
  bulkInviteSchema,
  async (data) => {
    const event = getRequestEvent();
    const supabase = event.locals.supabase;
    
    if (data.invites.length === 0) {
      throw new Error('No invites to send');
    }
    
    const response = await supabase.functions.invoke('bulk_invite_with_subscription', {
      body: { invites: data.invites },
      method: 'POST'
    });
    
    if (response.error) {
      throw new Error('Failed to process invitations. Please try again later.');
    }
    
    return { 
      success: 'Invitations are being processed. You will be notified when completed.' 
    };
  }
);
```

Update `invite-drawer.svelte` using the new `Field` component:

```svelte
<script lang="ts">
  import { validateSingleInvite, submitBulkInvites } from './data.remote';
  import { adminInviteSchema } from '$lib/schemas/adminInvite';
  import * as Field from '$lib/components/ui/field';
  import * as Sheet from '$lib/components/ui/sheet';
  import * as Card from '$lib/components/ui/card';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import { Separator } from '$lib/components/ui/separator';
  import { ScrollArea } from '$lib/components/ui/scroll-area';
  import DatePicker from '$lib/components/ui/date-picker.svelte';
  import PhoneInput from '$lib/components/ui/phone-input.svelte';
  import { Plus, Trash2 } from 'lucide-svelte';
  import { fromDate, getLocalTimeZone } from '@internationalized/date';
  import dayjs from 'dayjs';

  let isOpen = $state(false);
  
  // Local state for the invite list (since we're building it client-side)
  let invitesList = $state<Array<{
    firstName: string;
    lastName: string;
    email: string;
    phoneNumber: string;
    dateOfBirth: Date;
  }>>([]);

  // Date picker value for single invite form
  const dobValue = $derived.by(() => {
    const dob = validateSingleInvite.fields.dateOfBirth.value() as Date | undefined;
    if (!dob || !dayjs(dob).isValid()) return undefined;
    return fromDate(dayjs(dob).toDate(), getLocalTimeZone());
  });

  // Add current invite to the list
  async function addInviteToList() {
    // Trigger validation
    validateSingleInvite.validate({ includeUntouched: true });
    
    // Check if valid (no issues)
    const hasErrors = validateSingleInvite.fields.allIssues().length > 0;
    if (hasErrors) return;
    
    // Get values and add to list
    const values = validateSingleInvite.fields.value();
    invitesList = [...invitesList, {
      firstName: values.firstName || '',
      lastName: values.lastName || '',
      email: values.email,
      phoneNumber: values.phoneNumber || '',
      dateOfBirth: values.dateOfBirth || new Date()
    }];
    
    // Reset single invite form
    validateSingleInvite.fields.set({
      firstName: '',
      lastName: '',
      email: '',
      phoneNumber: '',
      dateOfBirth: undefined
    });
  }

  // Remove invite from list
  function removeInvite(index: number) {
    invitesList = invitesList.filter((_, i) => i !== index);
  }

  // Clear all invites
  function clearAllInvites() {
    invitesList = [];
  }

  // Sync invites list to bulk form before submission
  function handleBulkSubmit() {
    submitBulkInvites.fields.invites.set(invitesList);
  }
</script>

<Sheet.Root bind:open={isOpen}>
  <Sheet.Content class="w-full sm:max-w-xl">
    <Sheet.Header>
      <Sheet.Title>Invite Members</Sheet.Title>
      <Sheet.Description>Add members to invite in bulk</Sheet.Description>
    </Sheet.Header>

    <ScrollArea class="h-[calc(100vh-200px)] pr-4">
      <!-- Single Invite Form (for adding to list) -->
      <form 
        {...validateSingleInvite.preflight(adminInviteSchema)}
        onsubmit={(e) => { e.preventDefault(); addInviteToList(); }}
        class="space-y-4 p-4"
      >
        <Field.Group>
          <div class="grid grid-cols-2 gap-4">
            <Field.Field>
              {@const fieldProps = validateSingleInvite.fields.firstName.as('text')}
              <Field.Label for={fieldProps.name}>First Name</Field.Label>
              <Input {...fieldProps} id={fieldProps.name} placeholder="First name" />
              {#each validateSingleInvite.fields.firstName.issues() as issue}
                <Field.Error>{issue.message}</Field.Error>
              {/each}
            </Field.Field>
            
            <Field.Field>
              {@const fieldProps = validateSingleInvite.fields.lastName.as('text')}
              <Field.Label for={fieldProps.name}>Last Name</Field.Label>
              <Input {...fieldProps} id={fieldProps.name} placeholder="Last name" />
              {#each validateSingleInvite.fields.lastName.issues() as issue}
                <Field.Error>{issue.message}</Field.Error>
              {/each}
            </Field.Field>
          </div>

          <Field.Field>
            {@const fieldProps = validateSingleInvite.fields.email.as('email')}
            <Field.Label for={fieldProps.name}>Email</Field.Label>
            <Input {...fieldProps} id={fieldProps.name} placeholder="Email address" />
            {#each validateSingleInvite.fields.email.issues() as issue}
              <Field.Error>{issue.message}</Field.Error>
            {/each}
          </Field.Field>

          <Field.Field>
            {@const fieldProps = validateSingleInvite.fields.phoneNumber.as('tel')}
            <Field.Label for={fieldProps.name}>Phone Number</Field.Label>
            <PhoneInput
              {...fieldProps}
              id={fieldProps.name}
              placeholder="Phone number"
              onChange={(v) => validateSingleInvite.fields.phoneNumber.set(String(v))}
            />
            {#each validateSingleInvite.fields.phoneNumber.issues() as issue}
              <Field.Error>{issue.message}</Field.Error>
            {/each}
          </Field.Field>

          <Field.Field>
            {@const { value, ...fieldProps } = validateSingleInvite.fields.dateOfBirth.as('date')}
            <Field.Label for={fieldProps.name}>Date of Birth</Field.Label>
            <DatePicker
              {...fieldProps}
              id={fieldProps.name}
              value={dobValue}
              onDateChange={(date) => date && validateSingleInvite.fields.dateOfBirth.set(date)}
            />
            {#each validateSingleInvite.fields.dateOfBirth.issues() as issue}
              <Field.Error>{issue.message}</Field.Error>
            {/each}
          </Field.Field>
        </Field.Group>

        <Button type="submit" variant="outline" class="w-full">
          <Plus class="mr-2 h-4 w-4" />
          Add to List
        </Button>
      </form>

      <Separator class="my-4" />

      <!-- Invites List -->
      {#if invitesList.length > 0}
        <div class="space-y-2 p-4">
          <div class="flex justify-between items-center">
            <h4 class="font-medium">Invites ({invitesList.length})</h4>
            <Button variant="ghost" size="sm" onclick={clearAllInvites}>
              Clear All
            </Button>
          </div>
          
          {#each invitesList as invite, index (invite.email)}
            <Card.Root class="p-3">
              <div class="flex justify-between items-center">
                <div>
                  <p class="font-medium">{invite.firstName} {invite.lastName}</p>
                  <p class="text-sm text-muted-foreground">{invite.email}</p>
                </div>
                <Button variant="ghost" size="icon" onclick={() => removeInvite(index)}>
                  <Trash2 class="h-4 w-4" />
                </Button>
              </div>
            </Card.Root>
          {/each}
        </div>

        <!-- Bulk Submit Form -->
        <form 
          {...submitBulkInvites}
          onsubmit={(e) => { handleBulkSubmit(); }}
          class="p-4"
        >
          <Button type="submit" class="w-full">
            Send {invitesList.length} Invitation{invitesList.length > 1 ? 's' : ''}
          </Button>
        </form>
      {:else}
        <div class="text-center text-muted-foreground p-8">
          No invites added yet. Use the form above to add invites.
        </div>
      {/if}
    </ScrollArea>
  </Sheet.Content>
</Sheet.Root>
```

---

## 2. Workshop Form (Shared Component with Complex Dates)

### Current Implementation

The workshop form:
- Is a shared component used by create and edit pages
- Has complex date/time handling with `dayjs`
- Uses `onSubmit` to transform dates before submission
- Has conditional field disabling based on workshop status

### New Implementation

Create `src/lib/components/workshop-form.remote.ts`:

```typescript
import { form, getRequestEvent } from '$app/server';
import { redirect } from '@sveltejs/kit';
import { CreateWorkshopSchema, UpdateWorkshopSchema } from '$lib/server/services/workshops';

export const createWorkshop = form(
  CreateWorkshopSchema,
  async (data) => {
    const event = getRequestEvent();
    const { session } = await event.locals.safeGetSession();
    
    if (!session) throw new Error('Unauthorized');
    
    const workshopService = createWorkshopService(event.platform!, session);
    const workshop = await workshopService.create(data);
    
    redirect(303, `/dashboard/workshops/${workshop.id}`);
  }
);

export const updateWorkshop = form(
  UpdateWorkshopSchema,
  async (data) => {
    const event = getRequestEvent();
    const { session } = await event.locals.safeGetSession();
    const workshopId = event.params.id;
    
    if (!session) throw new Error('Unauthorized');
    
    const workshopService = createWorkshopService(event.platform!, session);
    await workshopService.update(workshopId, data);
    
    return { success: 'Workshop updated successfully' };
  }
);
```

Update `workshop-form.svelte` using the new `Field` component:

```svelte
<script lang="ts">
  import { createWorkshop, updateWorkshop } from './workshop-form.remote';
  import { CreateWorkshopSchema, UpdateWorkshopSchema } from '$lib/server/services/workshops';
  import * as Field from '$lib/components/ui/field';
  import { Input } from '$lib/components/ui/input';
  import { Textarea } from '$lib/components/ui/textarea';
  import { Button } from '$lib/components/ui/button';
  import Calendar25 from '$lib/components/calendar-25.svelte';
  import { 
    type CalendarDate, 
    fromDate, 
    getLocalTimeZone, 
    toCalendarDate, 
    toCalendarDateTime 
  } from '@internationalized/date';
  import dayjs from 'dayjs';
  import utc from 'dayjs/plugin/utc';
  import timezone from 'dayjs/plugin/timezone';

  dayjs.extend(utc);
  dayjs.extend(timezone);

  interface Props {
    mode: 'create' | 'edit';
    initialData?: Record<string, unknown>;
    workshopStatus?: string | null;
    workshopEditable?: boolean;
    priceEditingDisabled?: boolean;
    onSuccess?: () => void;
  }

  let { 
    mode, 
    initialData, 
    workshopStatus, 
    workshopEditable,
    priceEditingDisabled = false,
    onSuccess 
  }: Props = $props();

  // Select the appropriate form based on mode
  const formObj = mode === 'create' ? createWorkshop : updateWorkshop;
  const schema = mode === 'create' ? CreateWorkshopSchema : UpdateWorkshopSchema;

  // Populate initial data on mount
  $effect(() => {
    if (initialData && mode === 'edit') {
      formObj.fields.set(initialData);
    }
  });

  // Date handling
  const workshopDateValue = $derived.by(() => {
    const date = formObj.fields.workshop_date.value() as Date | undefined;
    if (!date || !dayjs(date).isValid()) return undefined;
    return toCalendarDate(fromDate(dayjs(date).toDate(), getLocalTimeZone()));
  });

  const startTime = $derived.by(() => {
    const date = formObj.fields.workshop_date.value() as Date | undefined;
    if (!date || !dayjs(date).isValid()) return '';
    return dayjs(date).format('HH:mm');
  });

  const endTime = $derived.by(() => {
    const date = formObj.fields.workshop_end_date.value() as Date | undefined;
    if (!date || !dayjs(date).isValid()) return '';
    return dayjs(date).format('HH:mm');
  });

  function updateWorkshopDates(
    date?: CalendarDate | string,
    op: 'start' | 'end' | 'date' = 'date'
  ) {
    if (!date) return;

    if (typeof date === 'string' && op === 'start') {
      const [hour, minute] = date.split(':').map(Number);
      const currentDate = dayjs(formObj.fields.workshop_date.value() as Date);
      const baseDate = currentDate.isValid() ? currentDate : dayjs();
      formObj.fields.workshop_date.set(baseDate.hour(hour).minute(minute).toDate());
      return;
    }

    if (typeof date === 'string' && op === 'end') {
      const [hour, minute] = date.split(':').map(Number);
      let baseDate = dayjs(formObj.fields.workshop_end_date.value() as Date);
      if (!baseDate.isValid()) {
        baseDate = dayjs(formObj.fields.workshop_date.value() as Date);
      }
      if (!baseDate.isValid()) {
        baseDate = dayjs();
      }
      formObj.fields.workshop_end_date.set(baseDate.hour(hour).minute(minute).toDate());
      return;
    }

    // Handle CalendarDate
    if (typeof date !== 'string') {
      const startDate = dayjs(formObj.fields.workshop_date.value() as Date);
      const startTimeVal = startDate.isValid()
        ? { hour: startDate.hour(), minute: startDate.minute() }
        : { hour: 10, minute: 0 };

      const endDate = dayjs(formObj.fields.workshop_end_date.value() as Date);
      const endTimeVal = endDate.isValid()
        ? { hour: endDate.hour(), minute: endDate.minute() }
        : { hour: 12, minute: 0 };

      formObj.fields.workshop_date.set(
        toCalendarDateTime(date).set(startTimeVal).toDate(getLocalTimeZone())
      );
      formObj.fields.workshop_end_date.set(
        toCalendarDateTime(date).set(endTimeVal).toDate(getLocalTimeZone())
      );
    }
  }

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
</script>

<form {...formObj.preflight(schema)} class="space-y-6">
  <Field.Group>
    <Field.Field>
      {@const fieldProps = formObj.fields.title.as('text')}
      <Field.Label for={fieldProps.name}>Workshop Title</Field.Label>
      <Input 
        {...fieldProps}
        id={fieldProps.name}
        disabled={!isWorkshopEditable}
        placeholder="Enter workshop title" 
      />
      {#each formObj.fields.title.issues() as issue}
        <Field.Error>{issue.message}</Field.Error>
      {/each}
    </Field.Field>

    <Field.Field>
      {@const fieldProps = formObj.fields.description.as('text')}
      <Field.Label for={fieldProps.name}>Description</Field.Label>
      <Textarea 
        {...fieldProps}
        id={fieldProps.name}
        disabled={!isWorkshopEditable}
        placeholder="Workshop description" 
      />
      {#each formObj.fields.description.issues() as issue}
        <Field.Error>{issue.message}</Field.Error>
      {/each}
    </Field.Field>
  </Field.Group>

  <!-- Date and Time -->
  <Field.Set>
    <Field.Legend>Date and Time</Field.Legend>
    <div class="grid grid-cols-2 gap-4">
      <Field.Field>
        {@const { value, ...fieldProps } = formObj.fields.workshop_date.as('date')}
        <Field.Label for={fieldProps.name}>Date</Field.Label>
        <Calendar25
          value={workshopDateValue}
          onValueChange={(date) => updateWorkshopDates(date, 'date')}
          disabled={!isWorkshopEditable}
        />
        {#each formObj.fields.workshop_date.issues() as issue}
          <Field.Error>{issue.message}</Field.Error>
        {/each}
      </Field.Field>

      <div class="space-y-4">
        <Field.Field>
          <Field.Label for="start-time">Start Time</Field.Label>
          <Input
            id="start-time"
            type="time"
            value={startTime}
            oninput={(e) => updateWorkshopDates(e.currentTarget.value, 'start')}
            disabled={!isWorkshopEditable}
          />
        </Field.Field>
        <Field.Field>
          <Field.Label for="end-time">End Time</Field.Label>
          <Input
            id="end-time"
            type="time"
            value={endTime}
            oninput={(e) => updateWorkshopDates(e.currentTarget.value, 'end')}
            disabled={!isWorkshopEditable}
          />
          {#each formObj.fields.workshop_end_date.issues() as issue}
            <Field.Error>{issue.message}</Field.Error>
          {/each}
        </Field.Field>
      </div>
    </div>
  </Field.Set>

  <!-- Pricing -->
  <Field.Set>
    <Field.Legend>Pricing</Field.Legend>
    <div class="grid grid-cols-2 gap-4">
      <Field.Field>
        {@const fieldProps = formObj.fields.member_price.as('number')}
        <Field.Label for={fieldProps.name}>Member Price</Field.Label>
        <Input 
          {...fieldProps}
          id={fieldProps.name}
          disabled={!canEditPricing}
        />
        {#each formObj.fields.member_price.issues() as issue}
          <Field.Error>{issue.message}</Field.Error>
        {/each}
      </Field.Field>

      <Field.Field>
        {@const fieldProps = formObj.fields.non_member_price.as('number')}
        <Field.Label for={fieldProps.name}>Non-Member Price</Field.Label>
        <Input 
          {...fieldProps}
          id={fieldProps.name}
          disabled={!canEditPricing}
        />
        {#each formObj.fields.non_member_price.issues() as issue}
          <Field.Error>{issue.message}</Field.Error>
        {/each}
      </Field.Field>
    </div>
  </Field.Set>

  <Button type="submit">
    {mode === 'create' ? 'Create Workshop' : 'Update Workshop'}
  </Button>
</form>
```

---

## 3. Signup Flow Forms

The signup flow has multiple forms across the invitation confirmation process. These should be migrated similarly.

Create `src/routes/(public)/members/signup/[invitationId]/data.remote.ts`:

```typescript
import { form, getRequestEvent } from '$app/server';
import { confirmInvitationSchema } from '$lib/schemas/confirmInvitation';
// Import other schemas as needed

export const confirmInvitation = form(
  confirmInvitationSchema,
  async (data) => {
    const event = getRequestEvent();
    const invitationId = event.params.invitationId;
    
    // Your confirmation logic
    // ...
    
    return { success: true, nextStep: 'payment' };
  }
);
```

---

## Key Patterns for Complex Forms

### 1. Array Fields with Remote Functions

```svelte
<script>
  // Use local state for building arrays
  let items = $state([]);
  
  // Sync to form before submission
  function handleSubmit() {
    myForm.fields.items.set(items);
  }
</script>

<form {...myForm} onsubmit={handleSubmit}>
  {#each items as item, i}
    <!-- Render item -->
    <button onclick={() => items = items.filter((_, idx) => idx !== i)}>
      Remove
    </button>
  {/each}
</form>
```

### 2. Client-Side Only Validation

For forms that only validate client-side before calling an API:

```svelte
<form 
  {...myForm.preflight(schema)}
  onsubmit={async (e) => {
    e.preventDefault();
    myForm.validate({ includeUntouched: true });
    if (myForm.fields.allIssues().length > 0) return;
    
    // Call your API directly
    await fetch('/api/endpoint', {
      method: 'POST',
      body: JSON.stringify(myForm.fields.value())
    });
  }}
>
```

### 3. Populating Edit Forms

```svelte
<script>
  let { data } = $props();
  
  $effect(() => {
    if (data.existingRecord) {
      myForm.fields.set(data.existingRecord);
    }
  });
</script>
```

### 4. Date Transformations

Remote Functions receive the data as-is. If you need date transformations:

```typescript
export const myForm = form(
  schema,
  async (data) => {
    // Transform dates if needed
    const transformedData = {
      ...data,
      startDate: new Date(data.startDate).toISOString(),
      endDate: new Date(data.endDate).toISOString()
    };
    
    // Use transformed data
  }
);
```

---

## Testing

For each complex form:

1. **Array fields**: Add/remove items, verify list updates
2. **Date handling**: Select dates, verify correct timezone handling
3. **Conditional fields**: Toggle conditions, verify field visibility
4. **Validation**: Test all validation rules
5. **Submission**: Verify data reaches server correctly
6. **Progressive enhancement**: Test with JS disabled

---

## Next Step

Proceed to `06_cleanup.md` to remove superforms and formsnap dependencies.
