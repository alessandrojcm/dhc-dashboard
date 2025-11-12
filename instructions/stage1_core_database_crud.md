# Stage 1: Core Database Schema & Basic CRUD

## Overview

Foundation for workshop management by coordinators. Workshop coordinator can create, read, update, delete workshops.

## Context & Clarifications

### Key Design Decisions

- **Database naming**: `club_activities` schema to distinguish from existing beginners workshop
- **Frontend terminology**: "workshops" for user-facing elements
- **API pattern**: Mutation-only endpoints (use Supabase client for queries)
- **Data access**: Kysely for all mutations, Supabase client for queries

### Answered Questions

1. **Refund Policy Granularity**: Per workshop, default to 3 days before the workshop
2. **Capacity Management**: Hard capacity limits only (no waitlists)
3. **Recurring Workshops**: No recurring workshop support needed
4. **Member Verification**: Private workshops require members to be signed in, so authentication determines member status
5. **Workshop Categories**: No categories/tags needed
6. **Notification Preferences**: No preferences needed - members will get emails and/or discord notifications
7. **Payment Methods**: Multiple payment methods supported
8. **Cancellation Policies**: Same policy for all workshop types

## Database Changes

### `club_activities` table with core fields:

- **Basic info**: title, description, location
- **Scheduling**: start_date, end_date
- **Capacity**: max_capacity (hard limit, no waitlists)
- **Pricing**: price_member, price_non_member
- **Visibility**: is_public
- **Policies**: refund_policy enum (default: 3 days before workshop)
- **Status**: club_activity_status enum (planned, published, finished, cancelled)

### Additional Database Requirements:

- Status transition validation functions
- RLS policies for workshop_coordinator role
- Hard capacity enforcement (no waitlist system)

## API Endpoints (Mutation-only)

- `POST /api/workshops/` - Create workshop
- `PUT /api/workshops/[id]/` - Update workshop
- `DELETE /api/workshops/[id]/` - Delete workshop
- `POST /api/workshops/[id]/publish` - Publish workshop
- `POST /api/workshops/[id]/cancel` - Cancel workshop

### API Implementation Guidelines

- **Pattern consistency**: Follow existing endpoint patterns exactly
- **Security pattern**: Use roles: `['admin', 'president', 'beginners_coordinator']`
- **Response format**: Always return `{success: true, [resource]: updatedRecord}`
- **Error handling**: Use Sentry integration and error mapping patterns
- **Business logic**: Implement state validation before mutations (check current state, validate transitions)
- **Database transactions**: Use `executeWithRLS()` wrapper for all mutations

## Frontend

- Basic coordinator dashboard at `/dashboard/workshops/`
- Create/edit workshop forms with validation
- Workshop list view with status indicators
- State transition buttons (publish, cancel)

### Frontend Guidelines

- Use Svelte 5 syntax exclusively
- ALWAYS use svelte-shadcn components first, resort to tailwind 4 custom styles if components do not suffice
- Implement proper error handling and loading states
- Use TanStack Query for data fetching and caching
- Component naming: kebab-case (e.g., `workshop-detail.svelte`)

## Tests

- Database schema and constraint tests
- API endpoint tests
- Basic UI interaction tests

### Testing Requirements

- **Test Driven Development**: All code MUST be covered by tests
- **E2E Testing**: Use unique test data with timestamps and random suffixes
- **Authentication**: Always use `makeAuthenticatedRequest()` instead of direct authorization headers
- **Service dependencies**: E2E tests require all services running (supabase:start, supabase:functions:serve, dev)
- **Response format**: API responses follow `{success: true, [resource]: data}` pattern

## Security Requirements

- All mutations through Kysely with RLS enforcement
- Role-based access control throughout
- Input validation with Valibot schemas
- Secure handling of payment information

## Success Criteria

- Workshop coordinators can create workshops with all required fields
- Status transitions work correctly (planned → published → finished/cancelled)
- Hard capacity limits are enforced
- RLS policies prevent unauthorized access
- All mutations use Kysely with `executeWithRLS()`
- Frontend follows existing component patterns
- Comprehensive test coverage for all functionality
