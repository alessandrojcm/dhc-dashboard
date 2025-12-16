# Superforms to SvelteKit Remote Functions Migration

## Overview

This migration replaces `sveltekit-superforms` and `formsnap` with SvelteKit's built-in experimental Remote Functions `form()` API.

## Why Migrate?

- **Native Valibot support** - No adapters needed, schemas work directly
- **Progressive enhancement** - Works without JavaScript
- **No external dependencies** - Built into SvelteKit
- **Field-level validation** - `.issues()` API for each field
- **Type-safe field bindings** - `.as('text')`, `.as('email')`, etc.
- **Cleaner API** - Less boilerplate than superforms

## Prerequisites

Remote Functions is already enabled in `svelte.config.js`:

```javascript
kit: {
  experimental: {
    remoteFunctions: true
  }
},
compilerOptions: {
  experimental: {
    async: true
  }
}
```

## Migration Steps

| Step | File | Description |
|------|------|-------------|
| 1 | `01_refactor_form_components.md` | Refactor form components to remove formsnap dependency |
| 2 | `02_migrate_auth_form.md` | Migrate the auth login form (simplest form) |
| 3 | `03_migrate_waitlist_form.md` | Migrate the waitlist form (medium complexity) |
| 4 | `04_migrate_settings_forms.md` | Migrate settings and simple CRUD forms |
| 5 | `05_migrate_complex_forms.md` | Migrate complex forms (invite drawer, workshop form) |
| 6 | `06_cleanup.md` | Remove superforms/formsnap dependencies |

## Key Concepts

### Before (Superforms + Formsnap)

```svelte
<script>
  import { superForm } from 'sveltekit-superforms';
  import { valibotClient } from 'sveltekit-superforms/adapters';
  import * as Form from '$lib/components/ui/form';
  
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
</form>
```

### After (Remote Functions)

```svelte
<script>
  import { submitForm } from './data.remote';
  import * as Form from '$lib/components/ui/form';
  
  // No setup needed - form is ready to use
</script>

<form {...submitForm}>
  <Form.Field field={submitForm.fields.email} label="Email">
    <Input {...submitForm.fields.email.as('email')} />
  </Form.Field>
</form>
```

## MCP Server Available

**IMPORTANT**: Agents implementing these steps have access to the Svelte MCP server for up-to-date documentation. Use it to:

1. Look up Remote Functions `form()` API details
2. Verify Valibot Standard Schema integration
3. Check SvelteKit form actions documentation

## Files Affected

### Form Components (Step 1)
- `src/lib/components/ui/form/index.ts`
- `src/lib/components/ui/form/form-field.svelte`
- `src/lib/components/ui/form/form-label.svelte`
- `src/lib/components/ui/form/form-field-errors.svelte`
- `src/lib/components/ui/form/form-description.svelte`
- `src/lib/components/ui/form/form-element-field.svelte`
- `src/lib/components/ui/form/form-fieldset.svelte`
- `src/lib/components/ui/form/form-legend.svelte`
- `src/lib/components/ui/form/form-button.svelte`

### Forms to Migrate (Steps 2-5)
- `src/routes/auth/+page.svelte` + `+page.server.ts`
- `src/routes/(public)/waitlist/+page.svelte` + `+page.server.ts`
- `src/routes/dashboard/members/settings-sheet.svelte`
- `src/routes/dashboard/members/[memberId]/+page.svelte`
- `src/routes/dashboard/members/invite-drawer.svelte`
- `src/routes/dashboard/inventory/*/create/+page.svelte`
- `src/routes/dashboard/inventory/*/[id]/edit/+page.svelte`
- `src/routes/(public)/members/signup/[invitationId]/*.svelte`
- `src/lib/components/workshop-form.svelte`

## Validation Schemas

All existing Valibot schemas in `src/lib/schemas/` and `src/lib/server/services/*/` can be reused directly with Remote Functions - no changes needed!
