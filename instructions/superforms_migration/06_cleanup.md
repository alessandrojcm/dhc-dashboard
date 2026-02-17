# Step 6: Cleanup - Remove Superforms and Formsnap Dependencies

## Objective

After all forms have been migrated to Remote Functions, remove the superforms and formsnap dependencies from the project.

## MCP Server Available

**IMPORTANT**: You have access to the Svelte MCP server if you need to verify any SvelteKit patterns during cleanup.

## Prerequisites

Before running this step, ensure:

- [ ] All forms in Step 2 (auth) are migrated and tested
- [ ] All forms in Step 3 (waitlist) are migrated and tested
- [ ] All forms in Step 4 (settings/CRUD) are migrated and tested
- [ ] All forms in Step 5 (complex forms) are migrated and tested
- [ ] All tests pass: `pnpm test`
- [ ] Type checking passes: `pnpm check`

## Step 1: Verify No Remaining Superforms Usage

Run these commands to check for any remaining usage:

```bash
# Check for superforms imports
grep -r "sveltekit-superforms" src/

# Check for formsnap imports
grep -r "formsnap" src/

# Check for superForm function calls
grep -r "superForm" src/

# Check for superValidate calls
grep -r "superValidate" src/

# Check for valibotClient adapter
grep -r "valibotClient" src/
```

If any results are found, those files still need to be migrated. Go back to the appropriate step.

## Step 2: Remove Dependencies

```bash
pnpm remove sveltekit-superforms formsnap
```

## Step 3: Clean Up Old Form Components (if not already done)

If you kept the old formsnap-based components during migration, now is the time to ensure they're fully replaced.

The form components in `src/lib/components/ui/form/` should now:
- NOT import from `formsnap`
- NOT import from `sveltekit-superforms`
- Accept a `field` prop (Remote Functions field object)
- Use `field.issues()` for errors
- Use `field.as()` for input attributes

Verify each component:

```bash
# Check form components for old imports
grep -r "formsnap\|sveltekit-superforms" src/lib/components/ui/form/
```

## Step 4: Update Type Definitions

If you have any custom type definitions that reference superforms types, update them:

```bash
# Check for SuperValidated type usage
grep -r "SuperValidated" src/

# Check for FormPath type usage  
grep -r "FormPath" src/

# Check for other superforms types
grep -r "from 'sveltekit-superforms" src/
```

Replace with appropriate types or remove if no longer needed.

## Step 5: Clean Up Server Files

Ensure all `+page.server.ts` files that had form actions:

1. Have `actions` export removed (if using Remote Functions)
2. Have superforms imports removed
3. Keep `load` functions if they load non-form data

Example of a cleaned up server file:

```typescript
// Before
import { fail } from '@sveltejs/kit';
import { message, superValidate } from 'sveltekit-superforms';
import { valibot } from 'sveltekit-superforms/adapters';
import schema from '$lib/schemas/mySchema';

export const load = async () => {
  return {
    form: await superValidate(valibot(schema)),
    otherData: await fetchOtherData()
  };
};

export const actions = {
  default: async ({ request }) => {
    const form = await superValidate(request, valibot(schema));
    // ...
  }
};

// After
export const load = async () => {
  return {
    otherData: await fetchOtherData()
  };
};

// Actions removed - handled by data.remote.ts
```

## Step 6: Run Full Test Suite

```bash
# Type checking
pnpm check

# Unit tests
pnpm test:unit

# E2E tests (ensure all services are running)
pnpm test:e2e

# Lint
pnpm lint
```

## Step 7: Update AGENTS.md / CLAUDE.md

Update the project documentation to reflect the new form handling approach:

```markdown
#### Form Handling

This project uses SvelteKit Remote Functions for form handling:

- **Form definitions**: Create `.remote.ts` files alongside routes
- **Validation**: Use Valibot schemas directly (Standard Schema support)
- **Progressive enhancement**: Built-in, works without JavaScript
- **Field API**: Use `field.as('type')`, `field.issues()`, `field.value()`, `field.set()`

Example:
\`\`\`typescript
// data.remote.ts
import { form } from '$app/server';
import * as v from 'valibot';

export const myForm = form(
  v.object({ name: v.string() }),
  async (data) => {
    // Handle submission
  }
);
\`\`\`

\`\`\`svelte
<!-- +page.svelte -->
<script>
  import { myForm } from './data.remote';
</script>

<form {...myForm}>
  <input {...myForm.fields.name.as('text')} />
  <button>Submit</button>
</form>
\`\`\`
```

## Step 8: Clean Up package.json

Verify the dependencies are removed:

```json
{
  "devDependencies": {
    // These should be GONE:
    // "formsnap": "...",
    // "sveltekit-superforms": "...",
  }
}
```

## Step 9: Final Verification

1. Start the dev server: `pnpm dev`
2. Manually test each form:
   - Auth form (login)
   - Waitlist form
   - Member settings
   - Inventory CRUD forms
   - Invite drawer
   - Workshop form
   - Signup flow

3. Test progressive enhancement:
   - Disable JavaScript in browser
   - Submit forms
   - Verify they still work

## Rollback Plan

If issues are found after cleanup:

1. The old implementation is in git history
2. Re-add dependencies: `pnpm add sveltekit-superforms formsnap`
3. Revert specific files as needed

## Summary

After completing this step:

- ✅ `sveltekit-superforms` removed from dependencies
- ✅ `formsnap` removed from dependencies
- ✅ All forms use Remote Functions `form()` API
- ✅ Form components use the new field interface
- ✅ All tests pass
- ✅ Documentation updated

## Migration Complete! 🎉

The project is now using SvelteKit's native Remote Functions for all form handling, with:
- Native Valibot support
- Progressive enhancement
- No external form library dependencies
- Type-safe field bindings
- Cleaner, more maintainable code
