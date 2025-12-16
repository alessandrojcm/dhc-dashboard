# Step 3: Migrate Waitlist Form to Remote Functions

## Objective

Migrate the waitlist form (`src/routes/(public)/waitlist/`) from superforms to SvelteKit Remote Functions. This form has medium complexity with multiple fields, conditional guardian fields, and custom validation.

## MCP Server Available

**IMPORTANT**: You have access to the Svelte MCP server. Use it to look up:
- SvelteKit Remote Functions `form()` documentation
- Nested field access patterns
- Client-side validation with `.preflight()`
- `.validate()` for programmatic validation

## Current Implementation

### Files to Modify

1. `src/routes/(public)/waitlist/+page.server.ts`
2. `src/routes/(public)/waitlist/+page.svelte`
3. **NEW**: `src/routes/(public)/waitlist/data.remote.ts`

### Current Schema

Located at `src/lib/schemas/beginnersWaitlist.ts` - **Keep this file unchanged!**

The schema includes:
- Basic fields: firstName, lastName, email, phoneNumber, dateOfBirth
- Optional fields: pronouns, gender, socialMediaConsent, medicalConditions
- Conditional guardian fields (required if under 18)
- Cross-field validation with `v.forward()` and `v.partialCheck()`

### Current `+page.server.ts`

```typescript
import { error, fail } from '@sveltejs/kit';
import { message, superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import { createWaitlistService, WaitlistEntrySchema } from '$lib/server/services/members';
import { supabaseServiceClient } from '$lib/server/supabaseServiceClient';

export const load = async () => {
  const isWaitlistOpen = await supabaseServiceClient
    .from('settings')
    .select('value')
    .eq('key', 'waitlist_open')
    .single()
    .then((result) => result?.data?.value === 'true');
    
  if (!isWaitlistOpen) {
    error(401, 'The waitlist is currently closed');
  }
  
  return {
    form: await superValidate(valibot(WaitlistEntrySchema)),
    genders: await supabaseServiceClient.rpc('get_gender_options').then((res) => res.data ?? [])
  };
};

export const actions = {
  default: async (event) => {
    const form = await superValidate(event, valibot(WaitlistEntrySchema));
    if (!form.valid) return fail(422, { form });
    
    try {
      const waitlistService = createWaitlistService(event.platform!);
      await waitlistService.create(form.data);
    } catch (err) {
      return message(form, { error: 'Something went wrong' }, { status: 500 });
    }
    
    return message(form, { success: 'You have been added to the waitlist!' });
  }
};
```

## New Implementation

### 1. Create `src/routes/(public)/waitlist/data.remote.ts`

```typescript
import { form, getRequestEvent } from '$app/server';
import { invalid } from '@sveltejs/kit';
import beginnersWaitlist from '$lib/schemas/beginnersWaitlist';
import { createWaitlistService } from '$lib/server/services/members';

/**
 * Waitlist submission form
 * Uses the existing Valibot schema directly - no adapter needed!
 */
export const submitWaitlist = form(
  beginnersWaitlist,
  async (data, issue) => {
    const event = getRequestEvent();
    
    try {
      const waitlistService = createWaitlistService(event.platform!);
      await waitlistService.create(data);
    } catch (err) {
      console.error('Waitlist submission error:', err);
      
      // Check for specific error types
      if (err instanceof Error && err.message.includes('duplicate')) {
        invalid(issue.email('This email is already on the waitlist'));
      }
      
      // Generic error
      throw new Error('Something went wrong, please try again later.');
    }
    
    return { success: 'You have been added to the waitlist, we will be in contact soon!' };
  }
);
```

### 2. Update `src/routes/(public)/waitlist/+page.server.ts`

Keep the load function for non-form data, remove actions:

```typescript
import { error } from '@sveltejs/kit';
import { supabaseServiceClient } from '$lib/server/supabaseServiceClient';
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async () => {
  const isWaitlistOpen = await supabaseServiceClient
    .from('settings')
    .select('value')
    .eq('key', 'waitlist_open')
    .single()
    .throwOnError()
    .then((result) => result?.data?.value === 'true');
    
  if (!isWaitlistOpen) {
    error(401, 'The waitlist is currently closed, please come back later.');
  }
  
  return {
    genders: await supabaseServiceClient
      .rpc('get_gender_options')
      .then((res) => (res.data ?? []) as string[])
  };
};

// Actions removed - handled by Remote Functions
```

### 3. Update `src/routes/(public)/waitlist/+page.svelte`

```svelte
<script lang="ts">
  import { fromDate, getLocalTimeZone } from '@internationalized/date';
  import dayjs from 'dayjs';
  import { toast } from 'svelte-sonner';
  import { submitWaitlist } from './data.remote';
  import beginnersWaitlist, { isMinor } from '$lib/schemas/beginnersWaitlist';
  
  // UI Components
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import { Textarea } from '$lib/components/ui/textarea';
  import * as Card from '$lib/components/ui/card';
  import * as Alert from '$lib/components/ui/alert';
  import * as Form from '$lib/components/ui/form';
  import * as Select from '$lib/components/ui/select';
  import * as RadioGroup from '$lib/components/ui/radio-group';
  import { CheckCircled } from 'svelte-radix';
  import { Loader } from 'lucide-svelte';
  import DatePicker from '$lib/components/ui/date-picker.svelte';
  import PhoneInput from '$lib/components/ui/phone-input.svelte';

  let { data } = $props();

  // Derive if user is under 18 based on current date of birth value
  const dateOfBirthValue = $derived(submitWaitlist.fields.dateOfBirth.value() as Date | undefined);
  const isUnderAge = $derived.by(() => {
    if (!dateOfBirthValue || !dayjs(dateOfBirthValue).isValid()) {
      return false;
    }
    return isMinor(dateOfBirthValue);
  });

  // Date picker value conversion
  const dobPickerValue = $derived.by(() => {
    if (!dateOfBirthValue || !dayjs(dateOfBirthValue).isValid()) {
      return undefined;
    }
    return fromDate(dayjs(dateOfBirthValue).toDate(), getLocalTimeZone());
  });

  // Helper snippet for field explanations
  {#snippet whyThisField(text: string)}
    <p class="text-muted-foreground text-xs">{text}</p>
  {/snippet}
</script>

<svelte:head>
  <title>Dublin Hema Club - Waitlist Registration</title>
</svelte:head>

<Card.Root class="self-center">
  <Card.Header>
    <Card.Title class="prose prose-h1 text-xl">Waitlist Form</Card.Title>
    <Card.Description class="prose">
      Thanks for your interest in Dublin Hema Club! Please sign up for our waitlist, we will contact
      you once a spot for our beginners workshop opens
    </Card.Description>
  </Card.Header>
  <Card.Content class="overflow-auto max-h-[85svh]">
    <!-- Use preflight for client-side validation -->
    <form {...submitWaitlist.preflight(beginnersWaitlist)} class="flex flex-col gap-4 items-stretch">
      
      <!-- Name Fields -->
      <div class="flex gap-4 w-full justify-stretch">
        <Form.Field field={submitWaitlist.fields.firstName} label="First name" class="flex-1">
          {#snippet children(field)}
            <Input {...field.as('text')} placeholder="Enter your first name" />
          {/snippet}
        </Form.Field>

        <Form.Field field={submitWaitlist.fields.lastName} label="Last name" class="flex-1">
          {#snippet children(field)}
            <Input {...field.as('text')} placeholder="Enter your last name" />
          {/snippet}
        </Form.Field>
      </div>

      <!-- Email -->
      <Form.Field field={submitWaitlist.fields.email} label="Email">
        {#snippet children(field)}
          <Input {...field.as('email')} placeholder="Enter your email" />
        {/snippet}
      </Form.Field>

      <!-- Phone Number -->
      <Form.Field field={submitWaitlist.fields.phoneNumber} label="Phone number">
        {#snippet children(field)}
          <PhoneInput
            {...field.as('tel')}
            placeholder="Enter your phone number"
            phoneNumber={field.value() as string}
            onPhoneNumberChange={(value) => field.set(value)}
          />
        {/snippet}
      </Form.Field>

      <!-- Gender -->
      <Form.Field field={submitWaitlist.fields.gender} label="Gender">
        {#snippet children(field)}
          {@render whyThisField('This helps us maintain a balanced and inclusive training environment')}
          <Select.Root 
            type="single" 
            value={field.value() as string}
            onValueChange={(v) => field.set(v)}
          >
            <Select.Trigger {...field.as('text')}>
              {#if field.value()}
                <p class="capitalize">{field.value()}</p>
              {:else}
                Select your gender
              {/if}
            </Select.Trigger>
            <Select.Content>
              {#each data.genders as gender (gender)}
                <Select.Item class="capitalize" value={gender} label={gender} />
              {/each}
            </Select.Content>
          </Select.Root>
        {/snippet}
      </Form.Field>

      <!-- Pronouns -->
      <Form.Field field={submitWaitlist.fields.pronouns} label="Pronouns">
        {#snippet children(field)}
          {@render whyThisField('This helps us maintain a balanced and inclusive training environment')}
          <Input {...field.as('text')} placeholder="Enter your pronouns" />
          <Form.Description>Please separate with slashes (e.g. they/them).</Form.Description>
        {/snippet}
      </Form.Field>

      <!-- Date of Birth -->
      <Form.Field field={submitWaitlist.fields.dateOfBirth} label="Date of birth">
        {#snippet children(field)}
          {@render whyThisField('For insurance reasons, HEMA practitioners need to be at least 16 years old')}
          <DatePicker
            value={dobPickerValue}
            onDateChange={(date) => {
              if (date) {
                field.set(date);
              }
            }}
          />
          <!-- Hidden input for form submission -->
          <input type="hidden" name="dateOfBirth" value={dateOfBirthValue?.toISOString() ?? ''} />
        {/snippet}
      </Form.Field>

      <!-- Social Media Consent -->
      <Form.Fieldset>
        <span class="flex items-center gap-2">
          <p class="text-sm font-medium">Social media consent</p>
          {@render whyThisField('We sometimes take pictures for our social media')}
        </span>
        <RadioGroup.Root
          value={submitWaitlist.fields.socialMediaConsent.value() as string}
          onValueChange={(v) => submitWaitlist.fields.socialMediaConsent.set(v)}
          class="flex justify-start"
        >
          <div class="flex items-center space-x-3">
            <RadioGroup.Item value="no" />
            <Form.Label>No</Form.Label>
          </div>
          <div class="flex items-center space-x-3">
            <RadioGroup.Item value="yes_unrecognizable" />
            <Form.Label>If not recognizable (wearing a mask)</Form.Label>
          </div>
          <div class="flex items-center space-x-3">
            <RadioGroup.Item value="yes_recognizable" />
            <Form.Label>Yes</Form.Label>
          </div>
        </RadioGroup.Root>
        <Form.FieldErrors issues={submitWaitlist.fields.socialMediaConsent.issues()} />
      </Form.Fieldset>

      <!-- Medical Conditions -->
      <Form.Field field={submitWaitlist.fields.medicalConditions} label="Any medical condition?">
        {#snippet children(field)}
          <Textarea {...field.as('text')} placeholder="Enter any medical conditions" />
        {/snippet}
      </Form.Field>

      <!-- Guardian Fields (conditional) -->
      {#if isUnderAge}
        <div class="mt-4 p-4 bg-gray-50 rounded-md border border-gray-200">
          <h3 class="text-lg font-medium mb-4">Guardian Information (Required for under 18)</h3>

          <div class="flex gap-4 w-full justify-stretch">
            <Form.Field field={submitWaitlist.fields.guardianFirstName} label="Guardian First Name" class="flex-1">
              {#snippet children(field)}
                <Input {...field.as('text')} placeholder="Enter guardian's first name" />
              {/snippet}
            </Form.Field>

            <Form.Field field={submitWaitlist.fields.guardianLastName} label="Guardian Last Name" class="flex-1">
              {#snippet children(field)}
                <Input {...field.as('text')} placeholder="Enter guardian's last name" />
              {/snippet}
            </Form.Field>
          </div>

          <Form.Field field={submitWaitlist.fields.guardianPhoneNumber} label="Guardian Phone Number">
            {#snippet children(field)}
              <PhoneInput
                {...field.as('tel')}
                placeholder="Enter guardian's phone number"
                phoneNumber={field.value() as string}
                onPhoneNumberChange={(value) => field.set(value)}
              />
            {/snippet}
          </Form.Field>
        </div>
      {/if}

      <Button type="submit">
        Submit
      </Button>
    </form>
  </Card.Content>
</Card.Root>
```

## Key Migration Points

### 1. Date Handling

Superforms had `dateProxy` helper. With Remote Functions:
- Use `field.value()` to get current value
- Use `field.set(value)` to update
- Handle date conversion manually with dayjs

### 2. Phone Input Integration

The custom `PhoneInput` component needs to work with Remote Functions:
```svelte
<PhoneInput
  {...field.as('tel')}
  phoneNumber={field.value() as string}
  onPhoneNumberChange={(value) => field.set(value)}
/>
```

### 3. Select/RadioGroup Integration

For shadcn Select and RadioGroup components:
```svelte
<Select.Root 
  value={field.value() as string}
  onValueChange={(v) => field.set(v)}
>
```

### 4. Conditional Fields

The `isUnderAge` derived value works the same way, but reads from `field.value()` instead of `$formData`:
```typescript
const dateOfBirthValue = $derived(submitWaitlist.fields.dateOfBirth.value() as Date | undefined);
const isUnderAge = $derived.by(() => {
  if (!dateOfBirthValue) return false;
  return isMinor(dateOfBirthValue);
});
```

### 5. Client-Side Validation

Use `.preflight(schema)` to enable client-side validation:
```svelte
<form {...submitWaitlist.preflight(beginnersWaitlist)}>
```

## Testing

1. Start dev server: `pnpm dev`
2. Navigate to `/waitlist`
3. Test validation:
   - Submit empty form - should show errors
   - Enter invalid email - should show error
   - Enter valid data - should submit
4. Test conditional guardian fields:
   - Enter DOB making user under 18
   - Guardian fields should appear
   - Guardian fields should be required
5. Test progressive enhancement:
   - Disable JavaScript
   - Submit form - should still work

## Notes

- The existing Valibot schema with cross-field validation (`v.forward`, `v.partialCheck`) should work directly
- If cross-field validation doesn't work, check MCP docs for Remote Functions validation patterns
- The `PhoneInput` component may need adjustments - check its current props interface

## Next Step

Proceed to `04_migrate_settings_forms.md` to migrate simpler settings and CRUD forms.
