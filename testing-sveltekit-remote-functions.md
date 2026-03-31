# Testing SvelteKit Server Logic and Remote Functions in Vitest

Based on my research of SvelteKit documentation and community resources, here are the recommended approaches for testing SvelteKit server code and remote functions in Vitest:

## 1. Recommended Approaches for Testing SvelteKit Server Code/Remote Functions

### Unit Testing Approach
- **Server Logic Separation**: Separate business logic from SvelteKit-specific code by creating service layers
- **Direct Function Testing**: Test remote functions directly by mocking their runtime context
- **Integration Testing**: Test the complete flow including request handling, but with mocked environments

### Testing Strategy
- Use Vitest's built-in mocking capabilities for environment variables and platform objects
- Focus on testing the business logic rather than the SvelteKit infrastructure
- Create test fixtures that mimic real request contexts

## 2. Mocking `RequestEvent`, `platform`, `locals`, and `$env/*` Safely

### Creating Mock Context
```javascript
// In your test setup
const mockRequestEvent = {
  locals: {
    user: { id: 'test-user', role: 'admin' }
  },
  platform: {
    // mock platform properties
  },
  url: new URL('http://localhost/test'),
  request: new Request('http://localhost/test'),
  // Add other properties as needed
};

// For environment variables, set process.env in tests
process.env.MY_SECRET = 'test-value';
```

### Using Vitest Mocks
```javascript
import { vi } from 'vitest';
import { getRequestEvent } from '$app/server';

// Mock the module
vi.mock('$app/server', () => ({
  getRequestEvent: vi.fn(() => mockRequestEvent)
}));
```

## 3. Mocking `$app/server` Exports

Yes, mocking `$app/server` exports like `getRequestEvent` is a standard practice for unit testing.

### Caveats:
- Ensure all dependencies are properly mocked
- Be aware that `getRequestEvent` relies on AsyncLocalStorage context
- Keep mocks minimal and focused on what's being tested
- Consider using `vi.spyOn` for more granular control

```javascript
// Example of proper mocking
import { vi } from 'vitest';
import { getRequestEvent } from '$app/server';

vi.mock('$app/server', () => ({
  getRequestEvent: vi.fn(() => ({
    locals: { user: { id: 'test' } },
    platform: {},
    url: new URL('http://localhost'),
    request: new Request('http://localhost')
  }))
}));
```

## 4. Extracting Thin Adapters vs Deep Mocking

**Prefer thin adapters** over deep mocking for several reasons:

### Benefits of Thin Adapters:
- Clear separation of concerns
- Easier to test and maintain
- More predictable behavior
- Better alignment with SvelteKit's architecture

### Example Pattern:
```javascript
// Instead of deep mocking, create an adapter
export function createUserService(platform, locals) {
  return {
    async getUserById(id) {
      // This can be tested independently
      const user = await platform.db.users.findById(id);
      return user;
    }
  };
}

// In your remote function
import { createUserService } from '$lib/server/services/userService';

export const getUser = query(v.string(), async (userId) => {
  const event = getRequestEvent();
  const userService = createUserService(event.platform, event.locals);
  return await userService.getUserById(userId);
});
```

## 5. Practical Patterns for Remote Functions/Server Modules

### Service Layer Pattern:
```javascript
// src/lib/server/services/workshopService.ts
export class WorkshopService {
  constructor(private platform: App.Platform, private locals: App.Locals) {}

  async createWorkshop(data: WorkshopData) {
    // Business logic here
    return await this.platform.db.workshops.create(data);
  }

  async getWorkshop(id: string) {
    return await this.platform.db.workshops.findById(id);
  }
}

// src/routes/workshops/workshop.remote.ts
import { query, command } from '$app/server';
import { WorkshopService } from '$lib/server/services/workshopService';

export const getWorkshop = query(v.string(), async (id) => {
  const event = getRequestEvent();
  const service = new WorkshopService(event.platform, event.locals);
  return await service.getWorkshop(id);
});

export const createWorkshop = command(v.object({...}), async (data) => {
  const event = getRequestEvent();
  const service = new WorkshopService(event.platform, event.locals);
  return await service.createWorkshop(data);
});
```

### Test Pattern:
```javascript
// workshopService.test.ts
import { describe, it, expect, vi } from 'vitest';
import { WorkshopService } from '$lib/server/services/workshopService';

describe('WorkshopService', () => {
  it('should create a workshop', async () => {
    const mockPlatform = {
      db: {
        workshops: {
          create: vi.fn().mockResolvedValue({ id: '1', title: 'Test' })
        }
      }
    };

    const service = new WorkshopService(mockPlatform, {});
    const result = await service.createWorkshop({ title: 'Test' });
    
    expect(result).toEqual({ id: '1', title: 'Test' });
    expect(mockPlatform.db.workshops.create).toHaveBeenCalled();
  });
});
```

## 6. Tradeoffs Between Test Types

| Test Type | Coverage | Speed | Complexity | Recommendation |
|-----------|----------|--------|------------|----------------|
| **Unit Tests** | High (logic only) | Fast | Low | Primary for business logic |
| **Integration Tests** | Medium (full flow) | Medium | Medium | For remote function flows |
| **E2E Tests** | Full (real environment) | Slow | High | For end-to-end validation |

## 7. SvelteKit-Specific Guidance

### Key Documentation References:
- **Remote Functions**: https://svelte.dev/docs/kit/remote-functions
- **Server-only modules**: https://svelte.dev/docs/kit/server-only-modules
- **Testing**: https://svelte.dev/docs/svelte/testing
- **Hooks**: https://svelte.dev/docs/kit/hooks

### Important Considerations:
- Server-only modules are automatically skipped in tests due to `process.env.TEST === 'true'`
- Use `getRequestEvent()` within your tests to ensure proper context
- Environment variables should be mocked in test environments
- Consider using `vi.mock` to replace SvelteKit modules with test implementations

### Best Practice Implementation:
```javascript
// setupTests.ts
import { vi } from 'vitest';

// Mock SvelteKit modules for testing
vi.mock('$app/server', () => ({
  getRequestEvent: vi.fn(() => ({
    locals: {},
    platform: {},
    url: new URL('http://localhost'),
    request: new Request('http://localhost')
  })),
  query: vi.fn(),
  command: vi.fn(),
  form: vi.fn()
}));

// Set up environment for tests
process.env.NODE_ENV = 'test';
```

This approach allows you to test your SvelteKit server logic while maintaining clean separation between your business logic and framework-specific code, making your tests both reliable and maintainable.