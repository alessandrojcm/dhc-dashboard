# SERVICE LAYER

Domain-driven service architecture for all database operations.

## STRUCTURE

```
services/
├── shared/           # Common utilities (logger, test mocks, types)
├── members/          # MemberService, ProfileService, WaitlistService
├── workshops/        # WorkshopService, AttendanceService, RefundService, RegistrationService
├── inventory/        # ItemService, ContainerService, CategoryService, HistoryService
├── invitations/      # InvitationService
└── settings/         # SettingsService
```

## SERVICE TEMPLATE

```typescript
import * as v from 'valibot';
import { executeWithRLS, sentryLogger } from '$lib/server/services/shared';
import type { Kysely, Session, Transaction, Logger, KyselyDatabase } from '$lib/server/services/shared';

// 1. Validation schemas (exported for forms)
export const EntityCreateSchema = v.object({
  name: v.pipe(v.string(), v.minLength(1))
});
export type EntityCreateInput = v.InferOutput<typeof EntityCreateSchema>;

// 2. Service class
export class EntityService {
  private logger: Logger;

  constructor(
    private kysely: Kysely<KyselyDatabase>,
    private session: Session,
    logger?: Logger
  ) {
    this.logger = logger ?? console;
  }

  // Public method (creates transaction)
  async create(input: EntityCreateInput): Promise<Entity> {
    return executeWithRLS(this.kysely, { claims: this.session }, async (trx) => {
      return this._create(trx, input);
    });
  }

  // Private transactional (for cross-service coordination)
  async _create(trx: Transaction<KyselyDatabase>, input: EntityCreateInput): Promise<Entity> {
    return trx.insertInto('entities').values(input).returningAll().executeTakeFirstOrThrow();
  }
}

// 3. Factory function
export function createEntityService(platform: App.Platform, session: Session, logger?: Logger) {
  return new EntityService(getKyselyClient(platform.env.HYPERDRIVE), session, logger ?? sentryLogger);
}
```

## PATTERNS

### Public vs Private Methods

| Method | Transaction | Usage |
|--------|-------------|-------|
| `create()` | Creates own via `executeWithRLS` | Called from routes |
| `_create(trx)` | Receives transaction | Cross-service coordination |

### Cross-Service Coordination

```typescript
// Compose services in single transaction
return executeWithRLS(db, { claims: session }, async (trx) => {
  const item = await itemService._create(trx, itemData);
  await historyService._record(trx, item.id, 'created');
  return item;
});
```

### Error Handling

```typescript
throw new Error('Failed to create item', { 
  cause: { originalError: error, input } 
});
```

## TESTING

```typescript
import { createMockKysely, createMockSession, createMockLogger } from '$lib/server/services/shared';

const service = new EntityService(
  createMockKysely(),
  createMockSession(),
  createMockLogger()
);
```

## WHEN TO CREATE VS EXTEND

**Create new service**: New business domain, different tables, doesn't fit existing

**Extend existing**: New operations on same entities, related queries, optimizations

## REMOTE FUNCTIONS INTEGRATION

Remote functions (`.remote.ts` files) **MUST** use the service layer:

```typescript
// CORRECT: Use service layer
import { command, getRequestEvent } from '$app/server';
import { authorize } from '$lib/server/auth';
import { createWorkshopService } from '$lib/server/services/workshops';

export const publishWorkshop = command(
  v.pipe(v.string(), v.uuid()),
  async (workshopId) => {
    const { locals, platform } = getRequestEvent();
    const session = await authorize(locals, WORKSHOP_ROLES);
    const service = createWorkshopService(platform!, session);
    return await service.publish(workshopId);  // Use service method
  }
);

// WRONG: Direct Kysely access
export const publishWorkshop = command(
  v.pipe(v.string(), v.uuid()),
  async (workshopId) => {
    const { locals, platform } = getRequestEvent();
    const session = await authorize(locals, WORKSHOP_ROLES);
    const kysely = getKyselyClient(platform.env.HYPERDRIVE);
    // DON'T DO THIS - use service instead
    return executeWithRLS(kysely, { claims: session }, (db) => 
      db.updateTable('club_activities')...
    );
  }
);
```

**Key Rules**:
1. Instantiate service via factory: `createXxxService(platform, session)`
2. Call service public methods (not private `_transactional` methods)
3. Let service handle `executeWithRLS` internally
4. If method doesn't exist, add it to the service first

## ANTI-PATTERNS

- Direct Kysely in `+page.server.ts` - use service
- Direct Kysely in `.remote.ts` - use service (CRITICAL)
- Skipping `executeWithRLS()` - security violation
- Global service instances - use factory functions
- Validation in service - validate at form layer, services receive clean data
- Calling `_transactional` methods from routes - use public methods only
