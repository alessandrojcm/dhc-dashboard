# Data Layer Service Pattern Design

## Executive Summary

This document outlines a comprehensive refactoring plan to organize the data access layer using a service pattern organized by domain. Currently, database operations using Kysely are scattered across `+page.server.ts` files and a few standalone server modules, leading to code duplication and inconsistent patterns.

## Current State Analysis

### Existing Kysely Usage Locations

1. **Page Server Files** (Loaders/Actions):
   - Workshop management pages (create, edit, list, attendees)
   - Member management pages (profile, settings, list)
   - Inventory management pages (items, containers, categories)
   - Public pages (waitlist, member signup)
   - Settings pages

2. **Existing Service Modules**:
   - `src/lib/server/workshops.ts` - Workshop CRUD operations
   - `src/lib/server/attendance.ts` - Attendance tracking
   - `src/lib/server/refunds.ts` - Refund processing
   - `src/lib/server/kyselyRPCFunctions.ts` - Database RPC wrappers

3. **API Routes**:
   - Workshop endpoints (publish, cancel, register, attendance, refunds)
   - Member endpoints (subscription pause/resume)
   - Admin endpoints (invitations)

### Problems Identified

1. **Data Access Scattered Everywhere**: Direct Kysely queries in 20+ page.server files
2. **Code Duplication**: Similar join patterns and queries repeated across files
3. **Inconsistent Patterns**: Some use RLS (`executeWithRLS`), others use raw Kysely
4. **Mixed Concerns**: Business logic intermingled with data access
5. **Testing Difficulty**: Hard to unit test data access patterns
6. **No Clear Ownership**: Unclear which module owns which data domain

## Domain Separation Analysis

Based on the database schema and current usage patterns, I propose the following domain separation:

### 1. **Workshop Domain** (`club_activities`, `club_activity_registrations`)
**Tables:**
- `club_activities` (workshops)
- `club_activity_registrations` (attendee registrations)
- `club_activity_refunds`
- `club_activity_invitations`
- `club_activity_priority_members`

**Operations:**
- Workshop CRUD (create, read, update, delete, publish, cancel)
- Registration management (register, confirm, cancel)
- Attendance tracking (mark attendance, get attendance)
- Refund processing (request refund, process refund)
- Priority member management
- Workshop queries (by status, by date range, by attendee)

**Current Files Affected:**
- `src/routes/dashboard/workshops/*/+page.server.ts` (4 files)
- `src/lib/server/workshops.ts` (already exists)
- `src/lib/server/attendance.ts` (already exists)
- `src/lib/server/refunds.ts` (already exists)

### 2. **Member Domain** (`user_profiles`, `member_profiles`, `member_management_view`)
**Tables:**
- `user_profiles` (basic user info)
- `member_profiles` (membership-specific data)
- `member_management_view` (aggregated member data)
- `waitlist` (potential members)
- `waitlist_guardians` (for minors)

**Operations:**
- Member CRUD (create, read, update, deactivate)
- Member search and filtering
- Waitlist management (add, remove, convert to member)
- Membership data queries (with subscription info)
- Guardian management for minors

**Current Files Affected:**
- `src/routes/dashboard/members/*/+page.server.ts` (2 files)
- `src/routes/(public)/waitlist/+page.server.ts`
- `src/routes/(public)/members/signup/[invitationId]/+page.server.ts`
- `src/lib/server/kyselyRPCFunctions.ts` (partially)

### 3. **Inventory Domain** (`inventory_items`, `containers`, `equipment_categories`)
**Tables:**
- `inventory_items`
- `containers`
- `equipment_categories`
- `inventory_history`

**Operations:**
- Item CRUD (create, read, update, delete)
- Container CRUD (create, read, update, delete)
- Category CRUD (create, read, update, delete)
- Item movement tracking (change container)
- Inventory queries (by container, by category, by maintenance status)
- History tracking

**Current Files Affected:**
- `src/routes/dashboard/inventory/items/*/+page.server.ts` (3 files)
- `src/routes/dashboard/inventory/containers/*/+page.server.ts` (4 files)
- `src/routes/dashboard/inventory/categories/*/+page.server.ts` (3 files)
- `src/routes/dashboard/inventory/+page.server.ts`

### 4. **Invitation Domain** (`invitations`)
**Tables:**
- `invitations`

**Operations:**
- Invitation CRUD (create, read, update status)
- Invitation validation (check expiry, check status)
- Bulk invitation creation
- Invitation info retrieval (for signup flow)

**Current Files Affected:**
- `src/routes/(public)/members/signup/[invitationId]/+page.server.ts`
- `src/lib/server/kyselyRPCFunctions.ts` (invitation functions)

### 5. **Settings Domain** (`settings`)
**Tables:**
- `settings` (key-value configuration)

**Operations:**
- Settings CRUD (read, update)
- Settings by key
- Bulk settings retrieval

**Current Files Affected:**
- `src/routes/dashboard/members/+page.server.ts`
- `src/routes/dashboard/beginners-workshop/+page.server.ts`

## Proposed Service Architecture

### Directory Structure

```
src/lib/server/services/
├── workshops/
│   ├── workshop.service.ts          # Workshop CRUD operations
│   ├── registration.service.ts      # Registration management
│   ├── attendance.service.ts        # Attendance tracking
│   ├── refund.service.ts           # Refund processing
│   ├── types.ts                    # Domain-specific types
│   └── index.ts                    # Public API exports
├── members/
│   ├── member.service.ts           # Member CRUD operations
│   ├── waitlist.service.ts         # Waitlist management
│   ├── profile.service.ts          # Profile updates
│   ├── types.ts                    # Domain-specific types
│   └── index.ts                    # Public API exports
├── inventory/
│   ├── item.service.ts             # Item CRUD operations
│   ├── container.service.ts        # Container CRUD operations
│   ├── category.service.ts         # Category CRUD operations
│   ├── history.service.ts          # History tracking
│   ├── types.ts                    # Domain-specific types
│   └── index.ts                    # Public API exports
├── invitations/
│   ├── invitation.service.ts       # Invitation operations
│   ├── types.ts                    # Domain-specific types
│   └── index.ts                    # Public API exports
├── settings/
│   ├── settings.service.ts         # Settings operations
│   ├── types.ts                    # Domain-specific types
│   └── index.ts                    # Public API exports
└── shared/
    ├── base.service.ts             # Base service class/utilities
    ├── logger.ts                   # Logger interface and default implementation
    ├── types.ts                    # Shared types
    └── index.ts                    # Public API exports
```

### Service Pattern Design Principles

#### 1. **No Global Objects - Dependency Injection**

Services should NOT use global singletons. Instead, they should accept dependencies as constructor parameters or function arguments.

**❌ BAD (Current Pattern):**
```typescript
export async function createWorkshop(data, session, platform) {
  const kysely = getKyselyClient(platform.env.HYPERDRIVE);
  // ...
}
```

**✅ GOOD (Proposed Pattern):**
```typescript
export class WorkshopService {
  private logger: Logger;

  constructor(
    private kysely: Kysely<KyselyDatabase>,
    private session: Session,
    logger?: Logger
  ) {
    this.logger = logger ?? console;
  }

  async create(data: WorkshopCreateInput): Promise<Workshop> {
    this.logger.info('Creating workshop', { title: data.title });
    
    try {
      return executeWithRLS(this.kysely, { claims: this.session }, async (trx) => {
        // ...
      });
    } catch (error) {
      this.logger.error('Failed to create workshop', { error, data });
      throw error;
    }
  }
}

// Usage in page.server.ts:
const workshopService = new WorkshopService(
  getKyselyClient(platform.env.HYPERDRIVE),
  session,
  sentryLogger // or omit for console
);
```

#### 2. **Logger Dependency Injection**

All services accept an optional logger. If not provided, defaults to `console`:

```typescript
// src/lib/server/services/shared/logger.ts
export interface Logger {
  info(message: string, context?: Record<string, unknown>): void;
  error(message: string, context?: Record<string, unknown>): void;
  warn(message: string, context?: Record<string, unknown>): void;
  debug(message: string, context?: Record<string, unknown>): void;
}

// Sentry logger implementation
export const sentryLogger: Logger = {
  info(message, context) {
    console.info(message, context);
  },
  error(message, context) {
    Sentry.captureException(new Error(message), { extra: context });
    console.error(message, context);
  },
  warn(message, context) {
    Sentry.captureMessage(message, { level: 'warning', extra: context });
    console.warn(message, context);
  },
  debug(message, context) {
    console.debug(message, context);
  }
};
```

**Benefits**:
- Services can log with custom loggers (Sentry, structured logging, etc.)
- Defaults to console for simplicity
- Easy to test with mock loggers
- Consistent logging interface across all services

#### 3. **Factory Functions for Service Creation**

To simplify service instantiation in page handlers, provide factory functions:

```typescript
// src/lib/server/services/workshops/index.ts
export function createWorkshopService(
  platform: App.Platform,
  session: Session,
  logger?: Logger
): WorkshopService {
  return new WorkshopService(
    getKyselyClient(platform.env.HYPERDRIVE),
    session,
    logger
  );
}
```

#### 4. **Clear Separation of Concerns**

Each service should have a single responsibility:

- **Data Access Layer**: Services handle database queries/mutations
- **Business Logic Layer**: Services contain domain logic (validation, state transitions)
- **Integration Layer**: Services coordinate with external systems (Stripe, email)

#### 5. **Consistent API Patterns**

All services should follow consistent method naming:

- **Create**: `create()` - Create a new entity
- **Read**: `findById()`, `findMany()`, `findOne()` - Query entities
- **Update**: `update()`, `patch()` - Update entities
- **Delete**: `delete()`, `softDelete()` - Remove entities
- **Business Operations**: `publish()`, `cancel()`, `register()` - Domain-specific actions

#### 6. **Type Safety**

Each service should define clear input/output types:

```typescript
// types.ts
export type WorkshopCreateInput = {
  title: string;
  description: string;
  // ...
};

export type Workshop = {
  id: string;
  title: string;
  // ...
};

// workshop.service.ts
export class WorkshopService {
  async create(input: WorkshopCreateInput): Promise<Workshop> {
    // ...
  }
}
```

#### 7. **Transaction Support**

Services should support both standalone and transactional operations:

```typescript
export class WorkshopService {
  // Standalone operation (creates own transaction)
  async create(input: WorkshopCreateInput): Promise<Workshop> {
    return executeWithRLS(this.kysely, { claims: this.session }, async (trx) => {
      return this._create(trx, input);
    });
  }

  // Transactional operation (uses provided transaction)
  async _create(
    trx: Transaction<KyselyDatabase>,
    input: WorkshopCreateInput
  ): Promise<Workshop> {
    return trx
      .insertInto('club_activities')
      .values(input)
      .returningAll()
      .executeTakeFirstOrThrow();
  }
}
```

#### 8. **Error Handling**

Services should use standard JavaScript `Error` objects with the `cause` property for context:

```typescript
// workshop.service.ts
async findById(id: string): Promise<Workshop> {
  const workshop = await this.kysely
    .selectFrom('club_activities')
    .selectAll()
    .where('id', '=', id)
    .executeTakeFirst();

  if (!workshop) {
    throw new Error('Workshop not found', { 
      cause: { workshopId: id, context: 'WorkshopService.findById' }
    });
  }

  return workshop;
}

// For errors with underlying causes (e.g., database errors):
async update(id: string, input: WorkshopUpdateInput): Promise<Workshop> {
  try {
    return await executeWithRLS(this.kysely, { claims: this.session }, async (trx) => {
      // ... update logic
    });
  } catch (error) {
    throw new Error('Failed to update workshop', { 
      cause: { workshopId: id, originalError: error }
    });
  }
}
```

**Benefits**:
- Standard JavaScript Error API (supported since ES2022)
- Structured error context via `cause` property
- Works seamlessly with Sentry and logging
- No custom error class hierarchy to maintain
- Better stack traces

## Detailed Service Specifications

### Workshop Service

```typescript
export class WorkshopService {
  constructor(
    private kysely: Kysely<KyselyDatabase>,
    private session: Session
  ) {}

  // CRUD Operations
  async create(input: WorkshopCreateInput): Promise<Workshop>
  async findById(id: string): Promise<Workshop>
  async findMany(filters?: WorkshopFilters): Promise<Workshop[]>
  async update(id: string, input: WorkshopUpdateInput): Promise<Workshop>
  async delete(id: string): Promise<void>

  // Business Operations
  async publish(id: string): Promise<Workshop>
  async cancel(id: string): Promise<Workshop>
  async canEdit(id: string): Promise<boolean>
  async canEditPricing(id: string): Promise<boolean>

  // Queries
  async getAttendees(id: string): Promise<WorkshopAttendee[]>
  async getRefunds(id: string): Promise<WorkshopRefund[]>
  async getByStatus(status: WorkshopStatus): Promise<Workshop[]>
}
```

### Registration Service

```typescript
export class RegistrationService {
  constructor(
    private kysely: Kysely<KyselyDatabase>,
    private session: Session
  ) {}

  // CRUD Operations
  async create(input: RegistrationCreateInput): Promise<Registration>
  async findById(id: string): Promise<Registration>
  async findMany(filters?: RegistrationFilters): Promise<Registration[]>
  async update(id: string, input: RegistrationUpdateInput): Promise<Registration>
  async delete(id: string): Promise<void>

  // Business Operations
  async confirm(id: string): Promise<Registration>
  async cancel(id: string): Promise<Registration>

  // Queries
  async getByWorkshop(workshopId: string): Promise<Registration[]>
  async getByMember(memberId: string): Promise<Registration[]>
}
```

### Member Service

```typescript
export class MemberService {
  constructor(
    private kysely: Kysely<KyselyDatabase>,
    private session: Session
  ) {}

  // CRUD Operations
  async create(input: MemberCreateInput): Promise<Member>
  async findById(id: string): Promise<Member>
  async findMany(filters?: MemberFilters): Promise<Member[]>
  async update(id: string, input: MemberUpdateInput): Promise<Member>
  async deactivate(id: string): Promise<void>

  // Business Operations
  async updateProfile(id: string, input: ProfileUpdateInput): Promise<Member>
  async pauseSubscription(id: string, until: Date): Promise<void>
  async resumeSubscription(id: string): Promise<void>

  // Queries
  async getByEmail(email: string): Promise<Member | null>
  async getWithSubscription(id: string): Promise<MemberWithSubscription>
}
```

### Inventory Item Service

```typescript
export class InventoryItemService {
  constructor(
    private kysely: Kysely<KyselyDatabase>,
    private session: Session
  ) {}

  // CRUD Operations
  async create(input: ItemCreateInput): Promise<InventoryItem>
  async findById(id: string): Promise<InventoryItemWithRelations>
  async findMany(filters?: ItemFilters): Promise<InventoryItem[]>
  async update(id: string, input: ItemUpdateInput): Promise<InventoryItem>
  async delete(id: string): Promise<void>

  // Business Operations
  async moveToContainer(itemId: string, containerId: string, notes?: string): Promise<void>
  async markMaintenance(itemId: string, outForMaintenance: boolean): Promise<void>

  // Queries
  async getByContainer(containerId: string): Promise<InventoryItem[]>
  async getByCategory(categoryId: string): Promise<InventoryItem[]>
  async getHistory(itemId: string): Promise<InventoryHistory[]>
}
```

## Migration Strategy (Revised)

### Phase 1: Infrastructure Setup

**Goal**: Create the foundation for service-based architecture

**Tasks**:
1. Create directory structure under `src/lib/server/services/`
2. Create shared utilities in `services/shared/`:
   - Create `logger.ts` with Logger interface and sentryLogger implementation
   - Re-export kysely utilities (executeWithRLS, getKyselyClient, Transaction types)
   - Create base types (ServiceConfig, etc.)
3. Set up testing infrastructure for services

**Deliverables**:
- Directory structure created
- Shared utilities available
- Test setup complete

### Phase 2: Member/Profile Domain (Highest Priority)

**Goal**: Migrate member profile management (fewest dependencies)

**Affected Files**:
- `src/routes/dashboard/members/[memberId]/+page.server.ts` (loader + action)
- `src/lib/server/kyselyRPCFunctions.ts` (getMemberData, updateMemberData)

**Tasks**:
1. Create `services/members/member.service.ts`:
   - Export validation schemas (MemberUpdateSchema)
   - Implement `findById()`, `update()`, `_update()` (transactional)
   - Export types (MemberUpdateInput, Member)
2. Create `services/members/profile.service.ts` for profile-specific operations
3. Create factory function in `services/members/index.ts`
4. Refactor member page.server.ts to use new service
5. Write unit tests
6. Remove migrated functions from kyselyRPCFunctions.ts

**Deliverables**:
- MemberService fully implemented
- ProfileService fully implemented  
- Member profile pages migrated
- Tests passing
- Documentation updated

### Phase 3: Settings Domain

**Goal**: Migrate settings management (standalone, no dependencies)

**Affected Files**:
- `src/routes/dashboard/members/+page.server.ts` (settings actions)
- `src/routes/dashboard/beginners-workshop/+page.server.ts` (settings queries)

**Tasks**:
1. Create `services/settings/settings.service.ts`:
   - Export validation schemas (SettingsUpdateSchema)
   - Implement `findByKey()`, `update()`, `findMany()`
2. Create factory function
3. Refactor affected page.server.ts files
4. Write unit tests

**Deliverables**:
- SettingsService fully implemented
- Settings pages migrated
- Tests passing

### Phase 4: Waitlist Domain

**Goal**: Migrate waitlist management (depends on Member domain)

**Affected Files**:
- `src/routes/(public)/waitlist/+page.server.ts`
- `src/lib/server/kyselyRPCFunctions.ts` (insertWaitlistEntry)

**Tasks**:
1. Create `services/members/waitlist.service.ts`:
   - Export validation schemas (WaitlistEntrySchema)
   - Implement `create()`, `findMany()`, `updateStatus()`
2. Refactor waitlist page.server.ts
3. Write unit tests
4. Remove insertWaitlistEntry from kyselyRPCFunctions.ts

**Deliverables**:
- WaitlistService fully implemented
- Waitlist page migrated
- Tests passing

### Phase 5: Invitation Domain

**Goal**: Migrate invitation management (depends on Member domain)

**Affected Files**:
- `src/routes/(public)/members/signup/[invitationId]/+page.server.ts`
- `src/lib/server/kyselyRPCFunctions.ts` (invitation functions)

**Tasks**:
1. Create `services/invitations/invitation.service.ts`:
   - Export validation schemas
   - Implement `findById()`, `create()`, `updateStatus()`, `validate()`
   - Inject MemberService for user creation
2. Refactor signup page.server.ts
3. Write unit tests
4. Remove invitation functions from kyselyRPCFunctions.ts

**Deliverables**:
- InvitationService fully implemented
- Signup flow migrated
- Tests passing

### Phase 6: Workshop Domain

**Goal**: Migrate workshop management (depends on Member domain)

**Affected Files**:
- `src/routes/dashboard/workshops/create/+page.server.ts`
- `src/routes/dashboard/workshops/[id]/edit/+page.server.ts`
- `src/routes/dashboard/workshops/[id]/attendees/+page.server.ts`
- `src/lib/server/workshops.ts` (existing)
- `src/lib/server/attendance.ts` (existing)
- `src/lib/server/refunds.ts` (existing)
- Workshop API routes (8 files)

**Tasks**:
1. Create `services/workshops/workshop.service.ts`:
   - Migrate existing workshops.ts into class
   - Export validation schemas (WorkshopCreateSchema, WorkshopUpdateSchema)
2. Create `services/workshops/registration.service.ts`:
   - Handle registration logic
   - Inject MemberService and WorkshopService
3. Create `services/workshops/attendance.service.ts`:
   - Migrate existing attendance.ts into class
4. Create `services/workshops/refund.service.ts`:
   - Migrate existing refunds.ts into class
5. Refactor all workshop page.server.ts files
6. Refactor all workshop API routes
7. Write comprehensive unit tests
8. Delete old workshop service files

**Deliverables**:
- Complete workshop service suite
- All workshop pages migrated
- All workshop API routes migrated
- Tests passing

### Phase 7: Inventory Domain

**Goal**: Migrate inventory management (independent domain, largest migration)

**Affected Files**:
- `src/routes/dashboard/inventory/items/*/+page.server.ts` (3 files)
- `src/routes/dashboard/inventory/containers/*/+page.server.ts` (4 files)
- `src/routes/dashboard/inventory/categories/*/+page.server.ts` (3 files)
- `src/routes/dashboard/inventory/+page.server.ts` (dashboard)

**Tasks**:
1. Create `services/inventory/item.service.ts`:
   - Export validation schemas (ItemCreateSchema, ItemUpdateSchema)
   - Implement full CRUD + business operations
2. Create `services/inventory/container.service.ts`:
   - Export validation schemas
   - Implement full CRUD
3. Create `services/inventory/category.service.ts`:
   - Export validation schemas
   - Implement full CRUD
4. Create `services/inventory/history.service.ts`:
   - Track item movements
5. Refactor all 11 inventory page.server.ts files
6. Write comprehensive unit tests

**Deliverables**:
- Complete inventory service suite
- All inventory pages migrated
- Tests passing

### Phase 8: Cleanup & Documentation

**Goal**: Finalize migration and update documentation

**Tasks**:
1. Delete `src/lib/server/kyselyRPCFunctions.ts` (should be empty now)
2. Delete old service files (workshops.ts, attendance.ts, refunds.ts)
3. Update `AGENTS.md` with service pattern guidelines
4. Add JSDoc comments to all services
5. Create service usage guide
6. Run full test suite
7. Performance audit

**Deliverables**:
- All legacy code removed
- Documentation complete
- All tests passing
- Performance validated

## Timeline Estimate

- **Phase 1**: 1-2 days
- **Phase 2**: 2-3 days (Member/Profile)
- **Phase 3**: 1 day (Settings)
- **Phase 4**: 1-2 days (Waitlist)
- **Phase 5**: 2-3 days (Invitations)
- **Phase 6**: 3-4 days (Workshop - largest refactor with existing code)
- **Phase 7**: 4-5 days (Inventory - most files to migrate)
- **Phase 8**: 1-2 days (Cleanup)

**Total**: ~3-4 weeks for complete migration

## Testing Strategy

### Unit Tests

Each service should have comprehensive unit tests:

```typescript
// workshop.service.test.ts
describe('WorkshopService', () => {
  let service: WorkshopService;
  let mockKysely: MockedKysely;
  let mockSession: Session;

  beforeEach(() => {
    mockKysely = createMockKysely();
    mockSession = createMockSession();
    const mockLogger = { info: vi.fn(), error: vi.fn(), warn: vi.fn(), debug: vi.fn() };
    service = new WorkshopService(mockKysely, mockSession, mockLogger);
  });

  describe('create', () => {
    it('should create a workshop with valid data', async () => {
      // Test implementation
    });

    it('should throw error if title is missing', async () => {
      // Test implementation
    });
  });
});
```

### Integration Tests

Keep existing E2E tests, but add integration tests for complex service interactions:

```typescript
// workshop-registration.integration.test.ts
describe('Workshop Registration Flow', () => {
  it('should register member, process payment, and update attendance', async () => {
    const workshopService = createWorkshopService(platform, session);
    const registrationService = createRegistrationService(platform, session);

    const workshop = await workshopService.create(workshopData);
    const registration = await registrationService.create({
      workshopId: workshop.id,
      memberId: member.id,
    });
    // ...
  });
});
```

## Benefits of This Design

### 1. **Improved Maintainability**
- Single source of truth for each domain's data access
- Easy to find and update data access logic
- Reduced code duplication

### 2. **Better Testability**
- Services can be unit tested in isolation
- Easy to mock dependencies
- Clear boundaries for testing

### 3. **Enhanced Type Safety**
- Clear input/output types for all operations
- Type inference works better
- Compile-time guarantees

### 4. **Easier Refactoring**
- Changes to database schema only affect service layer
- Page handlers remain unchanged
- Business logic separated from data access

### 5. **Scalability**
- Easy to add new operations to existing domains
- Clear pattern for adding new domains
- Consistent API across all domains

### 6. **No Global State**
- Services are stateless (except for injected dependencies)
- Easy to reason about data flow
- No hidden dependencies

### 7. **Flexible Logging**
- Services accept optional logger dependency
- Defaults to console for simplicity
- Easy to inject Sentry or other logging providers
- Consistent logging interface across all services
- Better observability and debugging

## Design Decisions (Finalized)

### 1. Service Architecture: **Class-Based Services**
✅ Using classes for better dependency injection and state encapsulation.

All services accept an optional `Logger` dependency, defaulting to `console` if not provided.

### 2. Transaction Management: **Service Composition with Dependency Injection**
For cross-domain operations, services will accept other services as dependencies:

```typescript
export class RegistrationService {
  private logger: Logger;

  constructor(
    private kysely: Kysely<KyselyDatabase>,
    private session: Session,
    logger?: Logger,
    private workshopService?: WorkshopService,
    private memberService?: MemberService
  ) {
    this.logger = logger ?? console;
  }

  async registerMemberForWorkshop(
    memberId: string, 
    workshopId: string
  ): Promise<Registration> {
    // Service can coordinate with other services
    const workshop = await this.workshopService!.findById(workshopId);
    const member = await this.memberService!.findById(memberId);
    
    // Complex transaction spanning multiple domains
    return executeWithRLS(this.kysely, { claims: this.session }, async (trx) => {
      // Create registration using transaction
      const registration = await this._create(trx, { memberId, workshopId });
      
      // Other services can also use the same transaction if needed
      // by exposing _transactional methods
      
      return registration;
    });
  }
}
```

**Pattern**: Services can compose other services through constructor injection. For complex cross-domain transactions, expose `_transactional` methods that accept a `Transaction` object.

### 3. Validation Strategy: **Form Validation Only**
To avoid double validation and maintain DRY principles:

- **Forms/API layer**: Validate using Valibot schemas (as currently done)
- **Services**: Accept already-validated data, no re-validation
- **Service validation schemas**: Export Valibot schemas from service modules for reuse

```typescript
// member.service.ts
import * as v from 'valibot';

// Export schema for use in forms
export const MemberUpdateSchema = v.object({
  firstName: v.string(),
  lastName: v.string(),
  // ...
});

export type MemberUpdateInput = v.InferOutput<typeof MemberUpdateSchema>;

export class MemberService {
  // Service accepts validated input, no re-validation
  async update(id: string, input: MemberUpdateInput): Promise<Member> {
    // Input is already validated by form/API layer
    return executeWithRLS(this.kysely, { claims: this.session }, async (trx) => {
      // ...
    });
  }
}

// In +page.server.ts
import { MemberUpdateSchema } from '$lib/server/services/members';

const form = await superValidate(request, valibot(MemberUpdateSchema));
```

**Benefits**: 
- Single source of truth for validation schemas
- No double validation overhead
- Schemas co-located with service logic
- Type safety maintained through inferred types

### 4. Repository Pattern: **Keep Together**
✅ Data access and business logic will remain together in service classes for simplicity.

### 5. Service Composition: **Dependency Injection**
✅ Services will accept other services as constructor parameters when needed.

### 6. Error Handling: **Standard Errors**
✅ Using standard JavaScript `Error` objects instead of custom error classes to keep it simple.

### 7. Migration Priority: **Member/Profile Domain First**
✅ Starting with Member/Profile domain as it has the fewest dependencies, then:
1. Member/Profile Domain (minimal dependencies)
2. Settings Domain (standalone)
3. Invitation Domain (depends on Member)
4. Workshop Domain (depends on Member)
5. Inventory Domain (independent)

### 8. Migration Approach: **One Domain at a Time**
✅ Complete each domain fully before moving to the next, including:
- Service implementation
- Migration of all affected page.server files
- Migration of all affected API routes
- Unit tests
- Update documentation

## Finalized Approach

### Service Class Pattern

```typescript
// src/lib/server/services/members/member.service.ts
import * as v from 'valibot';
import type { Session } from '@supabase/supabase-js';
import { executeWithRLS, type Kysely, type Transaction, type Logger } from '../shared';

// Export validation schema for reuse in forms
export const MemberUpdateSchema = v.object({
  firstName: v.string(),
  lastName: v.string(),
  phoneNumber: v.optional(v.string()),
  // ...
});

export type MemberUpdateInput = v.InferOutput<typeof MemberUpdateSchema>;

export class MemberService {
  private logger: Logger;

  constructor(
    private kysely: Kysely<KyselyDatabase>,
    private session: Session,
    logger?: Logger
  ) {
    this.logger = logger ?? console;
  }

  // Public methods create their own transactions
  async update(id: string, input: MemberUpdateInput): Promise<Member> {
    this.logger.info('Updating member profile', { memberId: id });
    
    try {
      return executeWithRLS(this.kysely, { claims: this.session }, async (trx) => {
        return this._update(trx, id, input);
      });
    } catch (error) {
      this.logger.error('Failed to update member profile', { memberId: id, error });
      throw error;
    }
  }

  // Private transactional methods for cross-service coordination
  async _update(
    trx: Transaction<KyselyDatabase>,
    id: string,
    input: MemberUpdateInput
  ): Promise<Member> {
    return trx
      .updateTable('user_profiles')
      .set(input)
      .where('supabase_user_id', '=', id)
      .returningAll()
      .executeTakeFirstOrThrow();
  }
}
```

### Factory Function Pattern

```typescript
// src/lib/server/services/members/index.ts
import { sentryLogger } from '../shared/logger';

export function createMemberService(
  platform: App.Platform,
  session: Session,
  logger?: Logger
): MemberService {
  return new MemberService(
    getKyselyClient(platform.env.HYPERDRIVE),
    session,
    logger ?? sentryLogger // Default to Sentry logger in production
  );
}
```

### Usage in Page Handlers

```typescript
// src/routes/dashboard/members/[memberId]/+page.server.ts
import { createMemberService, MemberUpdateSchema } from '$lib/server/services/members';

export const actions = {
  'update-profile': async ({ event, platform }) => {
    const form = await superValidate(event, valibot(MemberUpdateSchema));
    if (!form.valid) return fail(422, { form });

    // Logger defaults to sentryLogger in factory function
    const memberService = createMemberService(platform, event.locals.session);
    const member = await memberService.update(event.params.memberId, form.data);
    
    return message(form, { success: 'Profile updated!' });
  }
};
```

This approach provides:
- ✅ No global objects - full dependency injection
- ✅ Class-based services for better organization
- ✅ Optional logger injection (defaults to console)
- ✅ Single validation at form/API layer
- ✅ Exported schemas for type safety
- ✅ Transaction support for complex operations
- ✅ Service composition through DI
- ✅ Simple, pragmatic error handling
- ✅ Clear migration path starting with Member domain
