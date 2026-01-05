# E2E TESTING

Playwright end-to-end tests with Supabase integration.

## STRUCTURE

```
e2e/
├── global-setup.ts       # Database reset via Snaplet before all tests
├── setupFunctions.ts     # Core DB/Stripe setup helpers
├── supabaseLogin.ts      # Auth helper
├── attendee-test-helpers.ts  # Workshop-specific helpers
├── *.spec.ts             # Test files
```

## PREREQUISITES

**All three services must run (in order):**
```bash
pnpm supabase:start
pnpm supabase:functions:serve
pnpm dev
```

## KEY HELPERS

### Authentication

```typescript
import { supabaseLogin } from './supabaseLogin';

// Login as existing user
await supabaseLogin(page, 'user@example.com', 'password');
```

### API Requests (Authenticated)

```typescript
import { makeAuthenticatedRequest } from './attendee-test-helpers';

const response = await makeAuthenticatedRequest(page, '/api/workshops/123/publish', {
  method: 'POST',
  data: { ... }
});
```

### Database Setup

```typescript
import { createMember, createWorkshop, getSupabaseServiceClient } from './setupFunctions';

// Create test member with Stripe
const { memberId, cleanUp } = await createMember({
  email: `test-${Date.now()}@example.com`,
  roles: ['member']
});

// Always cleanup after test
await cleanUp();
```

### Available Setup Functions

| Function | Purpose |
|----------|---------|
| `createMember()` | Full member with auth, profile, Stripe |
| `setupWaitlistedUser()` | User on waitlist |
| `setupInvitedUser()` | User with pending invite |
| `createWorkshop()` | Workshop in `club_activities` |
| `getSupabaseServiceClient()` | Service role client for elevated ops |

## UNIQUE DATA PATTERN

**ALWAYS generate unique identifiers:**

```typescript
const timestamp = Date.now();
const randomSuffix = Math.random().toString(36).substring(2, 7);
const email = `test-${timestamp}-${randomSuffix}@example.com`;
```

## RESPONSE VALIDATION

```typescript
// API responses follow this format
expect(response).toMatchObject({
  success: true,
  workshop: expect.objectContaining({ id: workshopId })
});
```

## TEST STRUCTURE

```typescript
import { test, expect } from '@playwright/test';
import { createMember, createWorkshop } from './setupFunctions';
import { supabaseLogin } from './supabaseLogin';

test.describe('Workshop Management', () => {
  let cleanUp: () => Promise<void>;
  let memberId: string;

  test.beforeAll(async () => {
    const result = await createMember({ 
      email: `admin-${Date.now()}@test.com`,
      roles: ['admin'] 
    });
    memberId = result.memberId;
    cleanUp = result.cleanUp;
  });

  test.afterAll(async () => {
    await cleanUp();
  });

  test('can publish workshop', async ({ page }) => {
    await supabaseLogin(page, email, password);
    // ... test logic
  });
});
```

## ANTI-PATTERNS

- Hardcoded test emails - causes conflicts
- Direct authorization headers - use `makeAuthenticatedRequest`
- Missing cleanup - leaks test data
- Running without edge functions - Stripe webhooks fail
