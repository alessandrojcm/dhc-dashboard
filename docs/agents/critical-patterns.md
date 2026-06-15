# Critical Patterns

## Service Layer (MANDATORY)

ALL database mutations go through services in `src/lib/server/services/`.

```typescript
// In +page.server.ts
const service = createEntityService(platform!, session);
const result = await service.create(validatedData);
```

- Factory functions for instantiation
- `executeWithRLS()` wrapper for all Kysely mutations
- Valibot schemas exported for form validation
- Private `_transactional` methods for cross-service coordination

## Database Access

| Context | Tool | Pattern |
|---------|------|---------|
| Client queries | Supabase client | `supabase.from().select()` |
| Server queries | Kysely + RLS | `executeWithRLS(db, {claims: session}, ...)` |
| Server mutations | Service layer | Via service class methods |

## Remote Functions (`.remote.ts`)

Remote functions MUST delegate to the service layer:

```typescript
// In *.remote.ts file
import { command, getRequestEvent } from '$app/server';
import { authorize } from '$lib/server/auth';
import { createWorkshopService } from '$lib/server/services/workshops';

export const deleteWorkshop = command(
  v.pipe(v.string(), v.uuid()),
  async (workshopId) => {
    const { locals, platform } = getRequestEvent();
    const session = await authorize(locals, WORKSHOP_ROLES);
    const service = createWorkshopService(platform!, session);
    await service.delete(workshopId);  // MUST use service
    return { success: true };
  }
);
```

- **NEVER** use raw Kysely/`executeWithRLS` in remote functions
- **ALWAYS** instantiate service via factory function
- Validation handled by Valibot schema (first arg to `command`/`query`)
- Authorization via `authorize()` or `locals.safeGetSession()`

## Forms

ALWAYS use Superforms + our form components:

```svelte
<Form.Field>
  <Form.Control><Form.Label />{input}</Form.Control>
  <Form.FieldErrors />
</Form.Field>
```

## API Response Format

```typescript
// Success
{ success: true, [resourceName]: data }

// Error
{ success: false, error: string }
```
