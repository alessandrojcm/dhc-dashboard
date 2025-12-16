# Step 2: Migrate Auth Form to Remote Functions

## Objective

Migrate the authentication form (`src/routes/auth/`) from superforms to SvelteKit Remote Functions `form()` API. This is the simplest form in the codebase and serves as the proof-of-concept.

## MCP Server Available

**IMPORTANT**: You have access to the Svelte MCP server. Use it to look up:
- SvelteKit Remote Functions `form()` documentation
- `getRequestEvent()` for accessing request context
- `redirect()` and `error()` usage in remote functions

## Current Implementation

### Files to Modify

1. `src/routes/auth/+page.server.ts` - Server-side validation and actions
2. `src/routes/auth/+page.svelte` - Form UI
3. **NEW**: `src/routes/auth/data.remote.ts` - Remote function definitions

### Current Schema

Located at `src/lib/schemas/authSchema.ts`:

```typescript
import * as v from 'valibot';

const authSchema = v.object({
  email: v.optional(v.pipe(v.string(), v.email())),
  auth_method: v.picklist(['discord', 'magic_link'])
});

export default authSchema;
```

### Current `+page.server.ts`

```typescript
import { fail, redirect } from '@sveltejs/kit';
import { message, setError, superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import authSchema from '$lib/schemas/authSchema';

export const load = async () => {
  const form = await superValidate(valibot(authSchema));
  return { form };
};

export const actions = {
  default: async ({ request, url, locals: { supabase } }) => {
    const form = await superValidate(request, valibot(authSchema));
    
    if (!form.valid) {
      return fail(400, { form });
    }
    
    const authMethod = form.data.auth_method;
    
    if (authMethod === 'discord') {
      const { data, error } = await supabase.auth.signInWithOAuth({
        provider: 'discord',
        options: { redirectTo: `${url.origin}/auth/callback?next=/dashboard` }
      });
      if (!error) redirect(303, data.url);
      setError(form, 'auth_method', error.message);
      return fail(403, { form });
    }
    
    if (authMethod === 'magic_link') {
      if (!form.data.email) {
        setError(form, 'email', 'Email is required');
        return fail(400, { form });
      }
      
      const { error } = await supabase.auth.signInWithOtp({
        email: form.data.email,
        options: { emailRedirectTo: `${url.origin}/auth/callback?next=/dashboard` }
      });
      
      if (error) {
        setError(form, 'email', error.message);
        return fail(400, { form });
      }
      
      return message(form, { success: 'Check your email for the magic link' });
    }
    
    setError(form, 'auth_method', 'Invalid authentication method');
    return fail(400, { form });
  }
};
```

### Current `+page.svelte`

```svelte
<script lang="ts">
  import { superForm } from 'sveltekit-superforms';
  import { valibotClient } from 'sveltekit-superforms/adapters';
  import authSchema from '$lib/schemas/authSchema';
  // ... other imports
  
  const { data } = $props();
  
  const form = superForm(data.form, {
    validators: valibotClient(authSchema),
    validationMethod: 'oninput',
    resetForm: false,
    onSubmit: () => { errorMessage = ''; }
  });
  
  const { form: formData, enhance, submitting, errors, message } = form;
</script>

<form method="POST" use:enhance>
  <!-- form content -->
</form>
```

## New Implementation

### 1. Create `src/routes/auth/data.remote.ts`

```typescript
import { form, getRequestEvent } from '$app/server';
import { redirect, invalid } from '@sveltejs/kit';
import * as v from 'valibot';

// Schema for magic link authentication
const magicLinkSchema = v.object({
  email: v.pipe(
    v.string(),
    v.nonEmpty('Email is required'),
    v.email('Please enter a valid email')
  )
});

// Schema for Discord authentication (no fields needed, just the action)
const discordSchema = v.object({});

/**
 * Magic link authentication form
 */
export const magicLinkAuth = form(
  magicLinkSchema,
  async (data, issue) => {
    const event = getRequestEvent();
    const supabase = event.locals.supabase;
    const url = event.url;

    const { error } = await supabase.auth.signInWithOtp({
      email: data.email,
      options: {
        emailRedirectTo: `${url.origin}/auth/callback?next=/dashboard`
      }
    });

    if (error) {
      // Use invalid() to set field-specific errors
      invalid(issue.email(error.message));
    }

    // Return success message - form will display this
    return { success: 'Check your email for the magic link' };
  }
);

/**
 * Discord OAuth authentication
 * This is a simple redirect, so we use a minimal form
 */
export const discordAuth = form(
  discordSchema,
  async () => {
    const event = getRequestEvent();
    const supabase = event.locals.supabase;
    const url = event.url;

    const { data, error } = await supabase.auth.signInWithOAuth({
      provider: 'discord',
      options: {
        redirectTo: `${url.origin}/auth/callback?next=/dashboard`
      }
    });

    if (error) {
      // For OAuth errors, throw a general error
      throw new Error(error.message);
    }

    // Redirect to Discord OAuth page
    redirect(303, data.url);
  }
);
```

### 2. Update `src/routes/auth/+page.server.ts`

The server file becomes much simpler - just load data if needed:

```typescript
import type { PageServerLoad } from './$types';

export const load: PageServerLoad = async () => {
  // No form initialization needed - Remote Functions handle this
  return {};
};

// Actions are no longer needed - handled by Remote Functions
```

### 3. Update `src/routes/auth/+page.svelte`

```svelte
<script lang="ts">
  import { page } from '$app/state';
  import { Button } from '$lib/components/ui/button';
  import { Card } from '$lib/components/ui/card';
  import { DiscordLogo, ExclamationTriangle } from 'svelte-radix';
  import { Input } from '$lib/components/ui/input';
  import { Separator } from '$lib/components/ui/separator';
  import * as Alert from '$lib/components/ui/alert/index.js';
  import * as Form from '$lib/components/ui/form';
  import DHCLogo from '/src/assets/images/dhc-logo.png?enhanced';
  import { magicLinkAuth, discordAuth } from './data.remote';

  const hash = $derived(page.url.hash.split('#')[1] as string);
  let errorMessage = $derived(new URLSearchParams(hash).get('error_description'));
  const urlMessage = $derived(page.url.searchParams.get('message'));

  // Get success message from magic link form if available
  // Remote Functions return data is accessible via the form's return
</script>

<Card
  class="flex flex-col self-center w-[90%] sm:w-[80%] md:w-[70%] lg:w-[50%] max-w-md p-6 h-auto min-h-[24rem] justify-around items-center"
>
  <div class="md:hidden flex justify-center mb-4">
    <enhanced:img src={DHCLogo} alt="Dublin Hema Club Logo" class="w-24 h-24" />
  </div>
  <h2 class="prose font-bold prose-h2 text-2xl text-center">Log in to the DHC Dashboard</h2>
  
  {#if urlMessage}
    <Alert.Root variant="success" class="max-w-md mt-4">
      <Alert.Title>Success</Alert.Title>
      <Alert.Description>{urlMessage}</Alert.Description>
    </Alert.Root>
  {/if}
  
  {#if errorMessage}
    <Alert.Root variant="destructive" class="max-w-md mt-4">
      <ExclamationTriangle class="h-4 w-4" />
      <Alert.Title>Error</Alert.Title>
      <Alert.Description>{errorMessage}</Alert.Description>
    </Alert.Root>
  {/if}

  <!-- Discord OAuth Form -->
  <form {...discordAuth} class="w-full">
    <Button type="submit" variant="outline" class="w-full">
      <DiscordLogo class="mr-2 h-4 w-4" />
      Continue with Discord
    </Button>
  </form>

  <div class="flex items-center w-full gap-4 my-4">
    <Separator class="flex-1" />
    <span class="text-muted-foreground text-sm">or</span>
    <Separator class="flex-1" />
  </div>

  <!-- Magic Link Form -->
  <form {...magicLinkAuth} class="w-full space-y-4">
    <Form.Field field={magicLinkAuth.fields.email} label="Email">
      {#snippet children(field)}
        <Input
          {...field.as('email')}
          placeholder="Enter your email"
        />
      {/snippet}
    </Form.Field>
    
    <Button type="submit" class="w-full">
      Send Magic Link
    </Button>
  </form>
</Card>
```

## Key Differences

| Aspect | Superforms | Remote Functions |
|--------|------------|------------------|
| Form initialization | `superForm(data.form, {...})` | Import from `.remote.ts` |
| Form binding | `use:enhance` | `{...formObject}` spread |
| Field props | `{...props}` from snippet | `field.as('type')` |
| Errors | `$errors.fieldName` | `field.issues()` |
| Submitting state | `$submitting` | TBD - check docs |
| Server validation | `superValidate()` + `setError()` | `invalid(issue.field())` |
| Success messages | `message(form, {...})` | Return object from handler |

## Handling Success Messages

Remote Functions return values can be accessed. Check the Svelte MCP for the exact API, but typically:

```svelte
<script>
  import { magicLinkAuth } from './data.remote';
  
  // The form may have a way to access the last return value
  // Check MCP docs for: form return values, success state
</script>

{#if magicLinkAuth.result?.success}
  <Alert.Root variant="success">
    <Alert.Description>{magicLinkAuth.result.success}</Alert.Description>
  </Alert.Root>
{/if}
```

## Testing

1. Start the dev server: `pnpm dev`
2. Navigate to `/auth`
3. Test Discord OAuth button - should redirect to Discord
4. Test Magic Link:
   - Submit empty form - should show validation error
   - Submit valid email - should show success message
5. Verify progressive enhancement works (disable JS and test)

## Rollback Plan

If issues arise, the old implementation can be restored from git. The schema file is unchanged.

## Next Step

Proceed to `03_migrate_waitlist_form.md` to migrate a more complex form with multiple fields.
