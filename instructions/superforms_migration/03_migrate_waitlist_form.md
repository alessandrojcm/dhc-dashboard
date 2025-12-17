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

Using the new `Field` component from shadcn-svelte:

```svelte
<script lang="ts">
  import { fromDate, getLocalTimeZone } from '@internationalized/date';
  import dayjs from 'dayjs';
  import { submitWaitlist } from './data.remote';
  import { beginnersWaitlistClientSchema, isMinor } from '$lib/schemas/beginnersWaitlist';

  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import { Textarea } from '$lib/components/ui/textarea';
  import * as Card from '$lib/components/ui/card';
  import * as Alert from '$lib/components/ui/alert';
  import * as Field from '$lib/components/ui/field';
  import * as Select from '$lib/components/ui/select';
  import * as RadioGroup from '$lib/components/ui/radio-group';
  import { CheckCircled } from 'svelte-radix';
  import DatePicker from '$lib/components/ui/date-picker.svelte';
  import PhoneInput from '$lib/components/ui/phone-input.svelte';

  let { data } = $props();

  const dateOfBirthValue = $derived(submitWaitlist.fields.dateOfBirth.value() as string);
  const isUnderAge = $derived.by(() => {
    if (!dateOfBirthValue) return false;
    const date = new Date(dateOfBirthValue);
    if (!dayjs(date).isValid()) return false;
    return isMinor(date);
  });

  const dobPickerValue = $derived.by(() => {
    if (!dateOfBirthValue) return undefined;
    const date = new Date(dateOfBirthValue);
    if (!dayjs(date).isValid()) return undefined;
    return fromDate(date, getLocalTimeZone());
  });
</script>

{#snippet whyThisField(text: string)}
  <p class="text-muted-foreground text-xs">{text}</p>
{/snippet}

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
    {#if submitWaitlist.result?.success}
      <Alert.Root variant="success">
        <CheckCircled class="h-4 w-4" />
        <Alert.Description>{submitWaitlist.result.success}</Alert.Description>
      </Alert.Root>
    {:else}
      <form
        {...submitWaitlist.preflight(beginnersWaitlistClientSchema)}
        class="flex flex-col gap-4 items-stretch"
      >
        <Field.Group>
          <!-- Name Fields -->
          <div class="flex gap-4 w-full justify-stretch">
            <Field.Field class="flex-1">
              {@const fieldProps = submitWaitlist.fields.firstName.as('text')}
              <Field.Label for={fieldProps.name}>First name</Field.Label>
              <Input {...fieldProps} id={fieldProps.name} placeholder="Enter your first name" />
              {#each submitWaitlist.fields.firstName.issues() as issue}
                <Field.Error>{issue.message}</Field.Error>
              {/each}
            </Field.Field>

            <Field.Field class="flex-1">
              {@const fieldProps = submitWaitlist.fields.lastName.as('text')}
              <Field.Label for={fieldProps.name}>Last name</Field.Label>
              <Input {...fieldProps} id={fieldProps.name} placeholder="Enter your last name" />
              {#each submitWaitlist.fields.lastName.issues() as issue}
                <Field.Error>{issue.message}</Field.Error>
              {/each}
            </Field.Field>
          </div>

          <!-- Email -->
          <Field.Field>
            {@const fieldProps = submitWaitlist.fields.email.as('email')}
            <Field.Label for={fieldProps.name}>Email</Field.Label>
            <Input {...fieldProps} id={fieldProps.name} placeholder="Enter your email" />
            {#each submitWaitlist.fields.email.issues() as issue}
              <Field.Error>{issue.message}</Field.Error>
            {/each}
          </Field.Field>

          <!-- Phone Number -->
          <Field.Field>
            {@const fieldProps = submitWaitlist.fields.phoneNumber.as('tel')}
            <Field.Label for={fieldProps.name}>Phone number</Field.Label>
            <PhoneInput
              {...fieldProps}
              id={fieldProps.name}
              placeholder="Enter your phone number"
              onChange={(value) => submitWaitlist.fields.phoneNumber.set(String(value))}
            />
            {#each submitWaitlist.fields.phoneNumber.issues() as issue}
              <Field.Error>{issue.message}</Field.Error>
            {/each}
          </Field.Field>

          <!-- Gender -->
          <Field.Field>
            {@const fieldProps = submitWaitlist.fields.gender.as('select')}
            <Field.Label for={fieldProps.name}>Gender</Field.Label>
            {@render whyThisField('This helps us maintain a balanced and inclusive training environment')}
            <Select.Root
              type="single"
              value={submitWaitlist.fields.gender.value() as string}
              onValueChange={(v) => submitWaitlist.fields.gender.set(v)}
            >
              <Select.Trigger id={fieldProps.name}>
                {#if submitWaitlist.fields.gender.value()}
                  <p class="capitalize">{submitWaitlist.fields.gender.value()}</p>
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
            <input type="hidden" name={fieldProps.name} value={submitWaitlist.fields.gender.value() ?? ''} />
            {#each submitWaitlist.fields.gender.issues() as issue}
              <Field.Error>{issue.message}</Field.Error>
            {/each}
          </Field.Field>

          <!-- Pronouns -->
          <Field.Field>
            {@const fieldProps = submitWaitlist.fields.pronouns.as('text')}
            <Field.Label for={fieldProps.name}>Pronouns</Field.Label>
            {@render whyThisField('This helps us maintain a balanced and inclusive training environment')}
            <Input {...fieldProps} id={fieldProps.name} placeholder="Enter your pronouns" />
            <Field.Description>Please separate with slashes (e.g. they/them).</Field.Description>
            {#each submitWaitlist.fields.pronouns.issues() as issue}
              <Field.Error>{issue.message}</Field.Error>
            {/each}
          </Field.Field>

          <!-- Date of Birth -->
          <Field.Field>
            {@const { value, ...fieldProps } = submitWaitlist.fields.dateOfBirth.as('date')}
            <Field.Label for={fieldProps.name}>Date of birth</Field.Label>
            {@render whyThisField('For insurance reasons, HEMA practitioners need to be at least 16 years old')}
            <DatePicker
              {...fieldProps}
              id={fieldProps.name}
              value={dobPickerValue}
              onDateChange={(date) => {
                if (date) {
                  submitWaitlist.fields.dateOfBirth.set(date.toISOString());
                }
              }}
            />
            {#each submitWaitlist.fields.dateOfBirth.issues() as issue}
              <Field.Error>{issue.message}</Field.Error>
            {/each}
          </Field.Field>

          <!-- Medical Conditions -->
          <Field.Field>
            {@const fieldProps = submitWaitlist.fields.medicalConditions.as('text')}
            <Field.Label for={fieldProps.name}>Any medical condition?</Field.Label>
            <Textarea {...fieldProps} id={fieldProps.name} placeholder="Enter any medical conditions" />
            {#each submitWaitlist.fields.medicalConditions.issues() as issue}
              <Field.Error>{issue.message}</Field.Error>
            {/each}
          </Field.Field>
        </Field.Group>

        <!-- Social Media Consent -->
        <Field.Set>
          <span class="flex items-center gap-2">
            <Field.Legend>Social media consent</Field.Legend>
            {@render whyThisField('We sometimes take pictures for our social media')}
          </span>
          <RadioGroup.Root
            value={submitWaitlist.fields.socialMediaConsent.value() as string | undefined}
            onValueChange={(v) => submitWaitlist.fields.socialMediaConsent.set(v)}
            class="flex justify-start"
          >
            <div class="flex items-center space-x-3">
              <RadioGroup.Item value="no" id="no" />
              <Field.Label for="no">No</Field.Label>
            </div>
            <div class="flex items-center space-x-3">
              <RadioGroup.Item id="yes_unrecognizable" value="yes_unrecognizable" />
              <Field.Label for="yes_unrecognizable">If not recognizable (wearing a mask)</Field.Label>
            </div>
            <div class="flex items-center space-x-3">
              <RadioGroup.Item id="yes_recognizable" value="yes_recognizable" />
              <Field.Label for="yes_recognizable">Yes</Field.Label>
            </div>
          </RadioGroup.Root>
          {#each submitWaitlist.fields.socialMediaConsent.issues() as issue}
            <Field.Error>{issue.message}</Field.Error>
          {/each}
        </Field.Set>

        <!-- Guardian Fields (conditional) -->
        {#if isUnderAge}
          <Field.Set class="mt-4 p-4 bg-gray-50 rounded-md border border-gray-200">
            <Field.Legend>Guardian Information (Required for under 18)</Field.Legend>
            <Field.Group>
              <div class="flex gap-4 w-full justify-stretch">
                <Field.Field class="flex-1">
                  {@const fieldProps = submitWaitlist.fields.guardianFirstName.as('text')}
                  <Field.Label for={fieldProps.name}>Guardian First Name</Field.Label>
                  <Input {...fieldProps} id={fieldProps.name} placeholder="Enter guardian's first name" />
                  {#each submitWaitlist.fields.guardianFirstName.issues() as issue}
                    <Field.Error>{issue.message}</Field.Error>
                  {/each}
                </Field.Field>

                <Field.Field class="flex-1">
                  {@const fieldProps = submitWaitlist.fields.guardianLastName.as('text')}
                  <Field.Label for={fieldProps.name}>Guardian Last Name</Field.Label>
                  <Input {...fieldProps} id={fieldProps.name} placeholder="Enter guardian's last name" />
                  {#each submitWaitlist.fields.guardianLastName.issues() as issue}
                    <Field.Error>{issue.message}</Field.Error>
                  {/each}
                </Field.Field>
              </div>

              <Field.Field>
                {@const fieldProps = submitWaitlist.fields.guardianPhoneNumber.as('tel')}
                <Field.Label for={fieldProps.name}>Guardian Phone Number</Field.Label>
                <PhoneInput
                  {...fieldProps}
                  id={fieldProps.name}
                  placeholder="Enter guardian's phone number"
                  onChange={(value) => submitWaitlist.fields.guardianPhoneNumber.set(String(value))}
                />
                {#each submitWaitlist.fields.guardianPhoneNumber.issues() as issue}
                  <Field.Error>{issue.message}</Field.Error>
                {/each}
              </Field.Field>
            </Field.Group>
          </Field.Set>
        {/if}

        <Button type="submit">Submit</Button>
      </form>
    {/if}
  </Card.Content>
</Card.Root>
```

## Key Migration Points

### 1. Field Component Structure

The new `Field` component from shadcn-svelte uses this pattern:

```svelte
<Field.Field>
  {@const fieldProps = myForm.fields.fieldName.as('text')}
  <Field.Label for={fieldProps.name}>Label</Field.Label>
  <Input {...fieldProps} id={fieldProps.name} />
  <Field.Description>Helper text</Field.Description>
  {#each myForm.fields.fieldName.issues() as issue}
    <Field.Error>{issue.message}</Field.Error>
  {/each}
</Field.Field>
```

### 2. Phone Input Integration

The custom `PhoneInput` component works with Remote Functions:

```svelte
<Field.Field>
  {@const fieldProps = submitWaitlist.fields.phoneNumber.as('tel')}
  <Field.Label for={fieldProps.name}>Phone number</Field.Label>
  <PhoneInput
    {...fieldProps}
    id={fieldProps.name}
    placeholder="Enter your phone number"
    onChange={(value) => submitWaitlist.fields.phoneNumber.set(String(value))}
  />
  {#each submitWaitlist.fields.phoneNumber.issues() as issue}
    <Field.Error>{issue.message}</Field.Error>
  {/each}
</Field.Field>
```

### 3. Select Field Integration

For shadcn Select components, use a hidden input for form submission:

```svelte
<Field.Field>
  {@const fieldProps = submitWaitlist.fields.gender.as('select')}
  <Field.Label for={fieldProps.name}>Gender</Field.Label>
  <Select.Root
    type="single"
    value={submitWaitlist.fields.gender.value() as string}
    onValueChange={(v) => submitWaitlist.fields.gender.set(v)}
  >
    <Select.Trigger id={fieldProps.name}>
      {#if submitWaitlist.fields.gender.value()}
        <p class="capitalize">{submitWaitlist.fields.gender.value()}</p>
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
  <input type="hidden" name={fieldProps.name} value={submitWaitlist.fields.gender.value() ?? ''} />
  {#each submitWaitlist.fields.gender.issues() as issue}
    <Field.Error>{issue.message}</Field.Error>
  {/each}
</Field.Field>
```

### 4. Date Picker Integration

```svelte
<script lang="ts">
  import { fromDate, getLocalTimeZone } from '@internationalized/date';
  import dayjs from 'dayjs';

  const dateOfBirthValue = $derived(submitWaitlist.fields.dateOfBirth.value() as string);

  const dobPickerValue = $derived.by(() => {
    if (!dateOfBirthValue) return undefined;
    const date = new Date(dateOfBirthValue);
    if (!dayjs(date).isValid()) return undefined;
    return fromDate(date, getLocalTimeZone());
  });
</script>

<Field.Field>
  {@const { value, ...fieldProps } = submitWaitlist.fields.dateOfBirth.as('date')}
  <Field.Label for={fieldProps.name}>Date of birth</Field.Label>
  <DatePicker
    {...fieldProps}
    id={fieldProps.name}
    value={dobPickerValue}
    onDateChange={(date) => {
      if (date) {
        submitWaitlist.fields.dateOfBirth.set(date.toISOString());
      }
    }}
  />
  {#each submitWaitlist.fields.dateOfBirth.issues() as issue}
    <Field.Error>{issue.message}</Field.Error>
  {/each}
</Field.Field>
```

### 5. Radio Group with Field.Set

Use `Field.Set` for grouping related fields like radio groups:

```svelte
<Field.Set>
  <Field.Legend>Social media consent</Field.Legend>
  <Field.Description>We sometimes take pictures for our social media</Field.Description>
  <RadioGroup.Root
    value={submitWaitlist.fields.socialMediaConsent.value() as string | undefined}
    onValueChange={(v) => submitWaitlist.fields.socialMediaConsent.set(v)}
    class="flex justify-start"
  >
    <div class="flex items-center space-x-3">
      <RadioGroup.Item value="no" id="no" />
      <Field.Label for="no">No</Field.Label>
    </div>
    <!-- more options -->
  </RadioGroup.Root>
  {#each submitWaitlist.fields.socialMediaConsent.issues() as issue}
    <Field.Error>{issue.message}</Field.Error>
  {/each}
</Field.Set>
```

### 6. Conditional Fields

The `isUnderAge` derived value reads from `field.value()`:

```typescript
const dateOfBirthValue = $derived(submitWaitlist.fields.dateOfBirth.value() as string);
const isUnderAge = $derived.by(() => {
  if (!dateOfBirthValue) return false;
  const date = new Date(dateOfBirthValue);
  if (!dayjs(date).isValid()) return false;
  return isMinor(date);
});
```

### 7. Client-Side Validation

Use `.preflight(schema)` to enable client-side validation:

```svelte
<form {...submitWaitlist.preflight(beginnersWaitlistClientSchema)}>
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
