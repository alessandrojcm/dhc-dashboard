# Step 1: Install and Use the New shadcn-svelte Field Component

## Objective

Replace the deprecated `Form.Field` components (which depend on formsnap/superforms) with the new shadcn-svelte `Field` component. This component is designed to work with SvelteKit Remote Functions `form()` API and provides a cleaner, more accessible form structure.

## MCP Server Available

**IMPORTANT**: You have access to the Svelte MCP server. Use it to look up:
- SvelteKit Remote Functions `form()` documentation
- Field API (`.as()`, `.issues()`, `.value()`)
- Standard Schema validation

## Current State

The form components currently depend on:
- `formsnap` - Provides `Field`, `Control`, `Label`, `FieldErrors`, etc.
- `sveltekit-superforms` - Provides `FormPath` type and form state

### Current Files (to be replaced)

```
src/lib/components/ui/form/
├── index.ts                  # Exports all components
├── form-field.svelte         # Wraps FormPrimitive.Field
├── form-label.svelte         # Wraps FormPrimitive.Label
├── form-field-errors.svelte  # Wraps FormPrimitive.FieldErrors
├── form-description.svelte   # Wraps FormPrimitive.Description
├── form-element-field.svelte # Wraps FormPrimitive.ElementField
├── form-fieldset.svelte      # Wraps FormPrimitive.Fieldset
├── form-legend.svelte        # Wraps FormPrimitive.Legend
├── form-button.svelte        # Simple button wrapper (no formsnap)
```

## Target State

Use the new shadcn-svelte `Field` component which provides:
- `Field.Set` - Groups related fields with a legend
- `Field.Group` - Groups fields together
- `Field.Field` - Individual field wrapper
- `Field.Label` - Accessible label
- `Field.Description` - Helper text
- `Field.Error` - Error message display
- `Field.Separator` - Visual separator
- `Field.Content` - Content wrapper for responsive layouts
- `Field.Legend` - Legend for field sets

## Step 1: Install the Field Component

Run the shadcn-svelte CLI to add the Field component:

```bash
npx shadcn-svelte@next add field
```

This will create the new Field components in `src/lib/components/ui/field/`.

## Step 2: Understanding the New Field Component Structure

### Basic Structure

```svelte
<script lang="ts">
  import * as Field from "$lib/components/ui/field/index.js";
  import { Input } from "$lib/components/ui/input/index.js";
</script>

<Field.Set>
  <Field.Legend>Profile</Field.Legend>
  <Field.Description>This appears on invoices and emails.</Field.Description>
  <Field.Group>
    <Field.Field>
      <Field.Label for="name">Full name</Field.Label>
      <Input id="name" placeholder="Evil Rabbit" />
      <Field.Description>This appears on invoices and emails.</Field.Description>
    </Field.Field>
    <Field.Field>
      <Field.Label for="username">Username</Field.Label>
      <Input id="username" aria-invalid />
      <Field.Error>Choose another username.</Field.Error>
    </Field.Field>
  </Field.Group>
</Field.Set>
```

### Key Differences from Old Form Components

| Old (formsnap) | New (Field) |
|----------------|-------------|
| `Form.Field {form} name="email"` | `Field.Field` (no form binding) |
| `Form.Control` with snippet | Direct input placement |
| `Form.FieldErrors` | `Field.Error` |
| `Form.Description` | `Field.Description` |
| `Form.Fieldset` | `Field.Set` |
| `Form.Legend` | `Field.Legend` |

## Step 3: Integration with Remote Functions

The new Field component works seamlessly with Remote Functions. Here's how to integrate them:

### Remote Functions Field Object Interface

```typescript
// Remote Functions field object shape
interface RemoteFormField {
  as(type: string, value?: string): Record<string, unknown>;
  issues(): Array<{ message: string }>;
  value(): unknown;
  set(value: unknown): void;
}
```

### Basic Integration Pattern

```svelte
<script lang="ts">
  import { submitForm } from './data.remote';
  import * as Field from '$lib/components/ui/field';
  import { Input } from '$lib/components/ui/input';
</script>

<form {...submitForm}>
  <Field.Set>
    <Field.Group>
      <Field.Field>
        {@const fieldProps = submitForm.fields.email.as('email')}
        <Field.Label for={fieldProps.name}>Email</Field.Label>
        <Input {...fieldProps} id={fieldProps.name} placeholder="Enter your email" />
        {#each submitForm.fields.email.issues() as issue}
          <Field.Error>{issue.message}</Field.Error>
        {/each}
      </Field.Field>
    </Field.Group>
  </Field.Set>
</form>
```

## Step 4: Common Field Patterns

### Text Input Field

```svelte
<Field.Field>
  {@const fieldProps = submitForm.fields.firstName.as('text')}
  <Field.Label for={fieldProps.name}>First name</Field.Label>
  <Input {...fieldProps} id={fieldProps.name} placeholder="Enter your first name" />
  {#each submitForm.fields.firstName.issues() as issue}
    <Field.Error>{issue.message}</Field.Error>
  {/each}
</Field.Field>
```

### Email Input Field

```svelte
<Field.Field>
  {@const fieldProps = submitForm.fields.email.as('email')}
  <Field.Label for={fieldProps.name}>Email</Field.Label>
  <Input {...fieldProps} id={fieldProps.name} placeholder="Enter your email" />
  <Field.Description>We'll never share your email.</Field.Description>
  {#each submitForm.fields.email.issues() as issue}
    <Field.Error>{issue.message}</Field.Error>
  {/each}
</Field.Field>
```

### Phone Input Field (Custom Component)

```svelte
<Field.Field>
  {@const fieldProps = submitForm.fields.phoneNumber.as('tel')}
  <Field.Label for={fieldProps.name}>Phone number</Field.Label>
  <PhoneInput
    {...fieldProps}
    id={fieldProps.name}
    placeholder="Enter your phone number"
    onChange={(value) => submitForm.fields.phoneNumber.set(String(value))}
  />
  {#each submitForm.fields.phoneNumber.issues() as issue}
    <Field.Error>{issue.message}</Field.Error>
  {/each}
</Field.Field>
```

### Select Field

```svelte
<Field.Field>
  {@const fieldProps = submitForm.fields.gender.as('select')}
  <Field.Label for={fieldProps.name}>Gender</Field.Label>
  <Field.Description>This helps us maintain a balanced environment</Field.Description>
  <Select.Root
    type="single"
    value={submitForm.fields.gender.value() as string}
    onValueChange={(v) => submitForm.fields.gender.set(v)}
  >
    <Select.Trigger id={fieldProps.name}>
      {#if submitForm.fields.gender.value()}
        <p class="capitalize">{submitForm.fields.gender.value()}</p>
      {:else}
        Select your gender
      {/if}
    </Select.Trigger>
    <Select.Content>
      {#each genders as gender (gender)}
        <Select.Item class="capitalize" value={gender} label={gender} />
      {/each}
    </Select.Content>
  </Select.Root>
  <input type="hidden" name={fieldProps.name} value={submitForm.fields.gender.value() ?? ''} />
  {#each submitForm.fields.gender.issues() as issue}
    <Field.Error>{issue.message}</Field.Error>
  {/each}
</Field.Field>
```

### Date Picker Field

```svelte
<script lang="ts">
  import { fromDate, getLocalTimeZone } from '@internationalized/date';
  import dayjs from 'dayjs';
  
  const dateOfBirthValue = $derived(submitForm.fields.dateOfBirth.value() as string);
  
  const dobPickerValue = $derived.by(() => {
    if (!dateOfBirthValue) return undefined;
    const date = new Date(dateOfBirthValue);
    if (!dayjs(date).isValid()) return undefined;
    return fromDate(date, getLocalTimeZone());
  });
</script>

<Field.Field>
  {@const { value, ...fieldProps } = submitForm.fields.dateOfBirth.as('date')}
  <Field.Label for={fieldProps.name}>Date of birth</Field.Label>
  <Field.Description>For insurance reasons, you need to be at least 16 years old</Field.Description>
  <DatePicker
    {...fieldProps}
    id={fieldProps.name}
    value={dobPickerValue}
    onDateChange={(date) => {
      if (date) {
        submitForm.fields.dateOfBirth.set(date.toISOString());
      }
    }}
  />
  {#each submitForm.fields.dateOfBirth.issues() as issue}
    <Field.Error>{issue.message}</Field.Error>
  {/each}
</Field.Field>
```

### Textarea Field

```svelte
<Field.Field>
  {@const fieldProps = submitForm.fields.medicalConditions.as('text')}
  <Field.Label for={fieldProps.name}>Any medical condition?</Field.Label>
  <Textarea
    {...fieldProps}
    id={fieldProps.name}
    placeholder="Enter any medical conditions"
  />
  {#each submitForm.fields.medicalConditions.issues() as issue}
    <Field.Error>{issue.message}</Field.Error>
  {/each}
</Field.Field>
```

### Radio Group Field (using Field.Set)

```svelte
<Field.Set>
  <span class="flex items-center gap-2">
    <Field.Legend>Social media consent</Field.Legend>
    <Field.Description>We sometimes take pictures for our social media</Field.Description>
  </span>
  <RadioGroup.Root
    value={submitForm.fields.socialMediaConsent.value() as string | undefined}
    onValueChange={(v) => submitForm.fields.socialMediaConsent.set(v)}
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
  {#each submitForm.fields.socialMediaConsent.issues() as issue}
    <Field.Error>{issue.message}</Field.Error>
  {/each}
</Field.Set>
```

### Checkbox Field (Horizontal Orientation)

```svelte
<Field.Field orientation="horizontal">
  <Checkbox id="terms" checked={acceptTerms} onCheckedChange={(v) => acceptTerms = v} />
  <Field.Label for="terms" class="font-normal">
    I accept the terms and conditions
  </Field.Label>
</Field.Field>
```

## Step 5: Responsive Layout Pattern

For forms that need responsive layouts (label on left on desktop, stacked on mobile):

```svelte
<Field.Set>
  <Field.Legend>Profile</Field.Legend>
  <Field.Description>Fill in your profile information.</Field.Description>
  <Field.Separator />
  <Field.Group>
    <Field.Field orientation="responsive">
      <Field.Content>
        <Field.Label for="name">Name</Field.Label>
        <Field.Description>Provide your full name for identification</Field.Description>
      </Field.Content>
      <Input id="name" placeholder="Evil Rabbit" required />
    </Field.Field>
    <Field.Separator />
    <Field.Field orientation="responsive">
      <Field.Content>
        <Field.Label for="message">Message</Field.Label>
        <Field.Description>Keep it short, preferably under 100 characters.</Field.Description>
      </Field.Content>
      <Textarea id="message" placeholder="Hello, world!" class="min-h-[100px] resize-none" />
    </Field.Field>
  </Field.Group>
</Field.Set>
```

## Step 6: Complete Form Example

Here's a complete example showing all patterns together:

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

<Card.Root class="self-center">
  <Card.Header>
    <Card.Title class="prose prose-h1 text-xl">Waitlist Form</Card.Title>
    <Card.Description class="prose">
      Thanks for your interest! Please sign up for our waitlist.
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
          <!-- Name Fields (side by side) -->
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

          <!-- Gender Select -->
          <Field.Field>
            {@const fieldProps = submitWaitlist.fields.gender.as('select')}
            <Field.Label for={fieldProps.name}>Gender</Field.Label>
            <Field.Description>This helps us maintain a balanced environment</Field.Description>
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

          <!-- Date of Birth -->
          <Field.Field>
            {@const { value, ...fieldProps } = submitWaitlist.fields.dateOfBirth.as('date')}
            <Field.Label for={fieldProps.name}>Date of birth</Field.Label>
            <Field.Description>For insurance reasons, you need to be at least 16 years old</Field.Description>
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

        <!-- Social Media Consent (Radio Group) -->
        <Field.Set>
          <span class="flex items-center gap-2">
            <Field.Legend>Social media consent</Field.Legend>
            <Field.Description>We sometimes take pictures for our social media</Field.Description>
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
              <Field.Label for="yes_unrecognizable">If not recognizable</Field.Label>
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

        <!-- Conditional Guardian Fields -->
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

## Step 7: Keep Legacy Form Components (Optional)

If you need to maintain backward compatibility during migration, you can keep the old `Form` components alongside the new `Field` components. However, the recommended approach is to migrate all forms to use the new `Field` component.

The `form-button.svelte` component can be kept as-is since it doesn't depend on formsnap:

```svelte
<script lang="ts">
  import { Button, type ButtonProps } from '$lib/components/ui/button/index.js';

  let { ref = $bindable(null), ...restProps }: ButtonProps = $props();
</script>

<Button bind:ref type="submit" {...restProps} />
```

## Testing

After installing the Field component:

1. Run type checking: `pnpm check`
2. Verify the Field component is installed in `src/lib/components/ui/field/`
3. Test a simple form with the new Field component structure

## Notes

- The new `Field` component does NOT bind to form state - it's purely presentational
- Error display is manual - iterate over `field.issues()` and render `Field.Error`
- The `id` attribute is crucial for accessibility - use `fieldProps.name` for consistency
- For Select/DatePicker/PhoneInput, you need hidden inputs for form submission
- Use `Field.Set` for grouping related fields (like radio groups or address sections)

## Next Step

Proceed to `02_migrate_auth_form.md` to migrate the first form.
