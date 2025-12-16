# Step 1: Refactor Form Components to Remove Formsnap Dependency

## Objective

Refactor the form components in `src/lib/components/ui/form/` to work with SvelteKit Remote Functions `form()` API instead of formsnap/superforms, while maintaining a similar external API for ease of migration.

## MCP Server Available

**IMPORTANT**: You have access to the Svelte MCP server. Use it to look up:
- SvelteKit Remote Functions `form()` documentation
- Field API (`.as()`, `.issues()`, `.value()`)
- Standard Schema validation

## Current State

The form components currently depend on:
- `formsnap` - Provides `Field`, `Control`, `Label`, `FieldErrors`, etc.
- `sveltekit-superforms` - Provides `FormPath` type and form state

### Current Files

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

Components that work with Remote Functions field objects:

```typescript
// Remote Functions field object shape
interface RemoteFormField {
  as(type: string, value?: string): Record<string, unknown>;
  issues(): Array<{ message: string }>;
  value(): unknown;
  set(value: unknown): void;
}
```

## Implementation

### 1. Update `form-field.svelte`

**Before:**
```svelte
<script lang="ts" generics="T extends Record<string, unknown>, U extends FormPath<T>">
  import * as FormPrimitive from 'formsnap';
  import type { FormPath } from 'sveltekit-superforms';
  // ...
</script>

<FormPrimitive.Field {form} {name}>
  {#snippet children({ constraints, errors, tainted, value })}
    <div>...</div>
  {/snippet}
</FormPrimitive.Field>
```

**After:**
```svelte
<script lang="ts">
  import { cn, type WithElementRef, type WithoutChildren } from '$lib/utils.js';
  import type { HTMLAttributes } from 'svelte/elements';
  import type { Snippet } from 'svelte';

  /**
   * Remote Functions field object interface
   */
  interface RemoteFormField {
    as(type: string, value?: string): Record<string, unknown>;
    issues(): Array<{ message: string }>;
    value(): unknown;
    set(value: unknown): void;
  }

  interface Props extends WithoutChildren<WithElementRef<HTMLAttributes<HTMLDivElement>>> {
    /**
     * The field object from Remote Functions form
     * e.g., myForm.fields.email
     */
    field: RemoteFormField;
    /**
     * Optional label text
     */
    label?: string;
    /**
     * Children snippet - receives the field for custom rendering
     */
    children?: Snippet<[RemoteFormField]>;
  }

  let {
    ref = $bindable(null),
    class: className,
    field,
    label,
    children: childrenProp,
    ...restProps
  }: Props = $props();

  const hasErrors = $derived(field.issues().length > 0);
</script>

<div 
  bind:this={ref} 
  data-slot="form-item" 
  class={cn('space-y-2', className)} 
  {...restProps}
>
  {#if label}
    <label 
      class={cn(
        'text-sm font-medium leading-none peer-disabled:cursor-not-allowed peer-disabled:opacity-70',
        hasErrors && 'text-destructive'
      )}
    >
      {label}
    </label>
  {/if}
  
  {#if childrenProp}
    {@render childrenProp(field)}
  {/if}
  
  {#each field.issues() as issue}
    <p class="text-destructive text-sm font-medium">{issue.message}</p>
  {/each}
</div>
```

### 2. Update `form-label.svelte`

**After:**
```svelte
<script lang="ts">
  import { Label } from '$lib/components/ui/label/index.js';
  import { cn, type WithoutChild } from '$lib/utils.js';
  import type { HTMLLabelAttributes } from 'svelte/elements';

  interface Props extends HTMLLabelAttributes {
    ref?: HTMLLabelElement | null;
    hasError?: boolean;
  }

  let {
    ref = $bindable(null),
    children,
    class: className,
    hasError = false,
    ...restProps
  }: Props = $props();
</script>

<Label
  bind:ref
  data-slot="form-label"
  class={cn(hasError && 'text-destructive', className)}
  {...restProps}
>
  {@render children?.()}
</Label>
```

### 3. Update `form-field-errors.svelte`

**After:**
```svelte
<script lang="ts">
  import { cn } from '$lib/utils.js';
  import type { HTMLAttributes } from 'svelte/elements';

  interface Issue {
    message: string;
  }

  interface Props extends HTMLAttributes<HTMLDivElement> {
    ref?: HTMLDivElement | null;
    /**
     * Array of validation issues to display
     */
    issues?: Issue[];
    /**
     * Additional classes for each error message
     */
    errorClasses?: string | undefined | null;
  }

  let {
    ref = $bindable(null),
    class: className,
    issues = [],
    errorClasses,
    ...restProps
  }: Props = $props();
</script>

{#if issues.length > 0}
  <div
    bind:this={ref}
    class={cn('text-destructive text-sm font-medium', className)}
    {...restProps}
  >
    {#each issues as issue (issue.message)}
      <div class={cn(errorClasses)}>{issue.message}</div>
    {/each}
  </div>
{/if}
```

### 4. Update `form-description.svelte`

**After:**
```svelte
<script lang="ts">
  import { cn } from '$lib/utils.js';
  import type { HTMLAttributes } from 'svelte/elements';

  interface Props extends HTMLAttributes<HTMLParagraphElement> {
    ref?: HTMLParagraphElement | null;
  }

  let {
    ref = $bindable(null),
    class: className,
    children,
    ...restProps
  }: Props = $props();
</script>

<p
  bind:this={ref}
  data-slot="form-description"
  class={cn('text-muted-foreground text-sm', className)}
  {...restProps}
>
  {@render children?.()}
</p>
```

### 5. Update `form-fieldset.svelte`

**After:**
```svelte
<script lang="ts">
  import { cn } from '$lib/utils.js';
  import type { HTMLFieldsetAttributes } from 'svelte/elements';

  interface Props extends HTMLFieldsetAttributes {
    ref?: HTMLFieldSetElement | null;
  }

  let {
    ref = $bindable(null),
    class: className,
    children,
    ...restProps
  }: Props = $props();
</script>

<fieldset
  bind:this={ref}
  class={cn('space-y-2', className)}
  {...restProps}
>
  {@render children?.()}
</fieldset>
```

### 6. Update `form-legend.svelte`

**After:**
```svelte
<script lang="ts">
  import { cn } from '$lib/utils.js';
  import type { HTMLAttributes } from 'svelte/elements';

  interface Props extends HTMLAttributes<HTMLLegendElement> {
    ref?: HTMLLegendElement | null;
  }

  let {
    ref = $bindable(null),
    class: className,
    children,
    ...restProps
  }: Props = $props();
</script>

<legend
  bind:this={ref}
  class={cn('text-sm font-medium leading-none', className)}
  {...restProps}
>
  {@render children?.()}
</legend>
```

### 7. Update `form-element-field.svelte`

This component was for array element fields in superforms. With Remote Functions, array fields work differently using indexed access like `form.fields.items[0].name`.

**After:**
```svelte
<script lang="ts">
  import { cn, type WithElementRef, type WithoutChildren } from '$lib/utils.js';
  import type { HTMLAttributes } from 'svelte/elements';
  import type { Snippet } from 'svelte';

  interface RemoteFormField {
    as(type: string, value?: string): Record<string, unknown>;
    issues(): Array<{ message: string }>;
    value(): unknown;
    set(value: unknown): void;
  }

  interface Props extends WithoutChildren<WithElementRef<HTMLAttributes<HTMLDivElement>>> {
    field: RemoteFormField;
    children?: Snippet<[RemoteFormField]>;
  }

  let {
    ref = $bindable(null),
    class: className,
    field,
    children: childrenProp,
    ...restProps
  }: Props = $props();
</script>

<div bind:this={ref} class={cn('space-y-2', className)} {...restProps}>
  {#if childrenProp}
    {@render childrenProp(field)}
  {/if}
  
  {#each field.issues() as issue}
    <p class="text-destructive text-sm font-medium">{issue.message}</p>
  {/each}
</div>
```

### 8. Keep `form-button.svelte` as-is

This component doesn't use formsnap:

```svelte
<script lang="ts">
  import { Button, type ButtonProps } from '$lib/components/ui/button/index.js';

  let { ref = $bindable(null), ...restProps }: ButtonProps = $props();
</script>

<Button bind:ref type="submit" {...restProps} />
```

### 9. Update `index.ts`

**After:**
```typescript
import Description from './form-description.svelte';
import Label from './form-label.svelte';
import FieldErrors from './form-field-errors.svelte';
import Field from './form-field.svelte';
import Fieldset from './form-fieldset.svelte';
import Legend from './form-legend.svelte';
import ElementField from './form-element-field.svelte';
import Button from './form-button.svelte';

export {
  Field,
  Label,
  Button,
  FieldErrors,
  Description,
  Fieldset,
  Legend,
  ElementField,
  //
  Field as FormField,
  Description as FormDescription,
  Label as FormLabel,
  FieldErrors as FormFieldErrors,
  Fieldset as FormFieldset,
  Legend as FormLegend,
  ElementField as FormElementField,
  Button as FormButton
};

// Export the RemoteFormField type for consumers
export interface RemoteFormField {
  as(type: string, value?: string): Record<string, unknown>;
  issues(): Array<{ message: string }>;
  value(): unknown;
  set(value: unknown): void;
}
```

## Usage Example

### Before (Superforms + Formsnap)

```svelte
<script>
  import { superForm } from 'sveltekit-superforms';
  import { valibotClient } from 'sveltekit-superforms/adapters';
  import * as Form from '$lib/components/ui/form';
  import { Input } from '$lib/components/ui/input';
  
  const form = superForm(data.form, {
    validators: valibotClient(schema)
  });
  const { form: formData, enhance, submitting } = form;
</script>

<form method="POST" use:enhance>
  <Form.Field {form} name="email">
    <Form.Control>
      {#snippet children({ props })}
        <Form.Label>Email</Form.Label>
        <Input {...props} bind:value={$formData.email} />
      {/snippet}
    </Form.Control>
    <Form.FieldErrors />
  </Form.Field>
  
  <Form.Button disabled={$submitting}>Submit</Form.Button>
</form>
```

### After (Remote Functions)

```svelte
<script>
  import { submitForm } from './data.remote';
  import * as Form from '$lib/components/ui/form';
  import { Input } from '$lib/components/ui/input';
</script>

<form {...submitForm}>
  <Form.Field field={submitForm.fields.email} label="Email">
    {#snippet children(field)}
      <Input {...field.as('email')} />
    {/snippet}
  </Form.Field>
  
  <Form.Button>Submit</Form.Button>
</form>
```

## Testing

After refactoring, the components should:

1. Accept a `field` prop instead of `form` + `name`
2. Display errors via `field.issues()`
3. Not import anything from `formsnap` or `sveltekit-superforms`
4. Maintain styling consistency with the current design

Run type checking:
```bash
pnpm check
```

## Notes

- The `Form.Control` component is removed - it was a formsnap-specific wrapper
- Field attributes are now obtained via `field.as('text')` instead of snippet props
- Error display is simplified - just iterate over `field.issues()`
- The components are now framework-agnostic and could work with any form library that provides a similar field interface

## Next Step

Proceed to `02_migrate_auth_form.md` to migrate the first form.
